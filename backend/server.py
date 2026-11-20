from flask import Flask, render_template, request
from flask_socketio import SocketIO, emit
import subprocess
import threading
import queue
import os
import json
import glob

app = Flask(__name__, static_folder='../frontend', static_url_path='', template_folder='../frontend')
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='threading')


@app.after_request
def prevent_static_caching(resp):
    """En LAN el navegador no debe cachear HTML/CSS/JS (evita ver versiones viejas)."""
    path = request.path
    if path == '/' or path.endswith(('.html', '.css', '.js')):
        resp.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
        resp.headers['Pragma'] = 'no-cache'
        resp.headers['Expires'] = '0'
    return resp


def resolve_ydotool_socket():
    """Devuelve el socket de ydotoold a usar.

    Respeta YDOTOOL_SOCKET si ya viene definido por start.sh y, si no,
    detecta las ubicaciones habituales de ydotoold.
    """
    env_socket = os.environ.get('YDOTOOL_SOCKET')
    if env_socket:
        return env_socket

    uid = os.getuid()
    runtime_dir = os.environ.get('XDG_RUNTIME_DIR') or f'/run/user/{uid}'
    candidates = [
        os.path.join(runtime_dir, '.ydotool_socket'),
        f'/run/user/{uid}/.ydotool_socket',
        '/tmp/.ydotool_socket',
    ]

    for socket_candidate in candidates:
        if os.path.exists(socket_candidate):
            os.environ['YDOTOOL_SOCKET'] = socket_candidate
            return socket_candidate
    return None


YDOTOOL_SOCKET = resolve_ydotool_socket()


def check_ydotoold():
    """Solo informa el estado: el daemon lo gestiona start.sh / systemd."""
    if YDOTOOL_SOCKET and os.path.exists(YDOTOOL_SOCKET):
        print(f'[ℹ️ YDOTOOLD] Socket detectado en {YDOTOOL_SOCKET}')
    else:
        print('[⚠️ YDOTOOLD] No se detectó socket de ydotoold.')
        print('[⚠️ YDOTOOLD] Ejecutá ./start.sh para instalarlo y configurarlo.')


check_ydotoold()


# ---------------------------------------------------------------------------
# Integración con niri (compositor Wayland)
# ---------------------------------------------------------------------------
def niri_env():
    """Devuelve un entorno con NIRI_SOCKET resuelto para los subprocess.

    niri usa la variable NIRI_SOCKET. Si no está en el entorno (p.ej. el
    server corre desde systemd), la buscamos por glob en /run/user/<uid>.
    """
    env = dict(os.environ)
    sock = env.get('NIRI_SOCKET')
    if not sock:
        matches = sorted(glob.glob(f'/run/user/{os.getuid()}/niri.*.sock'))
        if matches:
            sock = matches[0]
    if sock:
        env['NIRI_SOCKET'] = sock
    return env


NIRI_ENV = niri_env()


# Acciones simples permitidas (sin argumentos)
NIRI_ALLOWED = {
    'close-window', 'fullscreen-window', 'toggle-windowed-fullscreen',
    'center-window', 'center-column', 'toggle-window-floating',
    'focus-window-previous',
    'focus-column-left', 'focus-column-right',
    'focus-column-first', 'focus-column-last',
    'move-column-left', 'move-column-right',
    'consume-window-into-column', 'expel-window-from-column',
    'toggle-column-tabbed-display',
    'focus-monitor-left', 'focus-monitor-right',
    'focus-monitor-up', 'focus-monitor-down',
    'focus-workspace-down', 'focus-workspace-up', 'focus-workspace-previous',
    'toggle-overview',
    'screenshot', 'screenshot-screen', 'screenshot-window',
    'show-hotkey-overlay',
}

# Acciones que reciben un número (índice); se valida el rango
NIRI_PARAM = {
    'focus-workspace': (1, 40),
    'move-window-to-workspace': (1, 40),
    'focus-column': (0, 100),
    'move-column-to-index': (0, 100),
}

# Acciones especiales mapeadas a un comando fijo (el cliente nunca envía el comando)
NIRI_SPECIAL = {
    'open-terminal': ['action', 'spawn', '--', 'kitty'],
    'quit': ['action', 'quit'],
}


def niri_command_parts(action, param=None):
    """Devuelve la lista argv para 'niri msg' o None si no está permitida."""
    if action in NIRI_SPECIAL:
        return NIRI_SPECIAL[action]
    if action in NIRI_ALLOWED:
        return ['action', action]
    if action in NIRI_PARAM and param is not None:
        try:
            idx = int(param)
        except (TypeError, ValueError):
            return None
        lo, hi = NIRI_PARAM[action]
        if lo <= idx <= hi:
            return ['action', action, str(idx)]
    return None


def niri_available():
    if not NIRI_ENV.get('NIRI_SOCKET'):
        return False
    try:
        res = subprocess.run(['niri', 'msg', 'version'], env=NIRI_ENV,
                             capture_output=True, text=True, timeout=1)
        return res.returncode == 0
    except Exception:
        return False


@socketio.on('niri_status')
def handle_niri_status():
    """El frontend consulta esto al conectar para mostrar/ocultar el botón."""
    return {'available': niri_available()}


@socketio.on('niri_action')
def handle_niri_action(data):
    """Ejecuta una acción de niri SOLO si está en la lista permitida."""
    try:
        action = str(data.get('action', ''))
        param = data.get('param')
    except Exception:
        emit('niri_result', {'ok': False, 'error': 'petición inválida'})
        return

    parts = niri_command_parts(action, param)
    if not parts:
        print(f'[NIRI] acción rechazada no permitida: {action}')
        emit('niri_result', {'ok': False, 'error': 'acción no permitida'})
        return

    try:
        res = subprocess.run(['niri', 'msg', *parts], env=NIRI_ENV,
                             capture_output=True, text=True, timeout=2)
        if res.returncode != 0:
            err = (res.stderr or 'fallo').strip().splitlines()[-1][:200]
            print(f'[NIRI] {action} -> código {res.returncode}: {err}')
            emit('niri_result', {'ok': False, 'error': err})
        else:
            print(f'[NIRI] acción ejecutada: {action}')
            emit('niri_result', {'ok': True})
    except Exception as e:
        print(f'[NIRI ERROR] {action}: {e}')
        emit('niri_result', {'ok': False, 'error': str(e)[:200]})


@socketio.on('niri_workspaces')
def handle_niri_workspaces():
    """Lee los escritorios virtuales de niri para pintar los chips."""
    try:
        res = subprocess.run(['niri', 'msg', '-j', 'workspaces'], env=NIRI_ENV,
                             capture_output=True, text=True, timeout=2)
        if res.returncode != 0:
            return {'ok': False}
        data = json.loads(res.stdout)
        workspaces = [{
            'id': w.get('id'),
            'idx': w.get('idx'),
            'name': w.get('name'),
            'active': w.get('is_active'),
            'focused': w.get('is_focused'),
            'output': w.get('output'),
        } for w in data]
        return {'ok': True, 'workspaces': workspaces}
    except Exception as e:
        return {'ok': False, 'error': str(e)[:200]}


# Queue y worker desacoplado para movimiento suave sin bloquear Socket.IO
move_queue = queue.Queue(maxsize=100)
is_dragging = False
drag_start_x = 0
drag_start_y = 0

def mouse_worker():
    """Worker en segundo plano que coalesce y ejecuta movimientos en ydotool"""
    while True:
        try:
            dx, dy = move_queue.get()
            # Coalesce: acumular movimientos pendientes para reducir forks de procesos
            while not move_queue.empty():
                try:
                    ndx, ndy = move_queue.get_nowait()
                    dx += ndx
                    dy += ndy
                    move_queue.task_done()
                except queue.Empty:
                    break

            if dx != 0 or dy != 0:
                result = subprocess.run(
                    ['ydotool', 'mousemove', '--', str(int(dx)), str(int(dy))],
                    capture_output=True,
                    timeout=0.3,
                    text=True
                )
                if result.returncode != 0:
                    print(f'[YDOTOOL ERROR] code={result.returncode}: {result.stderr.strip()}')
                else:
                    print(f'[MOVE EXECUTED] dx={dx}, dy={dy}')
            move_queue.task_done()
        except Exception as e:
            print(f'[WORKER ERROR] {e}')

threading.Thread(target=mouse_worker, daemon=True).start()

@app.route('/')
def index():
    return render_template('index.html')

@socketio.on('connect')
def handle_connect():
    print('\n✅ CLIENTE CONECTADO')
    emit('response', {'data': 'Conectado al servidor'})

@socketio.on('disconnect')
def handle_disconnect():
    global is_dragging
    print('Cliente desconectado')
    # Prevenir que el botón quede presionado en el OS si el cliente se desconecta abruptamente
    if is_dragging:
        is_dragging = False
        try:
            result = subprocess.run(['ydotool', 'click', '0x80'], capture_output=True, timeout=0.5, text=True)
            if result.returncode != 0:
                print(f"[DRAG CLEANUP ERROR] code={result.returncode}: {result.stderr.strip()}")
            else:
                print('[DRAG CLEANUP] Mouse button released after disconnect')
        except Exception as e:
            print(f'[DRAG CLEANUP ERROR] {e}')

@socketio.on('move_mouse')
def handle_move_mouse(data):
    """Encola deltas de movimiento para ejecución en segundo plano"""
    try:
        x = data.get('x', 0)
        y = data.get('y', 0)
        print(f'[RECV move_mouse] raw: x={x}, y={y}')
        if x != 0 or y != 0:
            x_int = int(round(x))
            y_int = int(round(y))
            try:
                move_queue.put_nowait((x_int, y_int))
            except queue.Full:
                # Si la cola está saturada, descartar paquetes viejos para evitar lag acumulado
                pass
    except Exception as e:
        print(f'[ERROR MOVE] {e}')

@socketio.on('click')
def handle_click(data):
    """Realiza un click (izquierdo, derecho o medio)"""
    try:
        button = data.get('button', 'left')
        # ydotool click v1 usa máscara hexadecimal:
        # 0xC0 = left click, 0xC1 = right click, 0xC2 = middle click
        button_map = {
            'left': '0xC0',
            'right': '0xC1',
            'middle': '0xC2'
        }
        button_code = button_map.get(button, '0xC0')
        result = subprocess.run(['ydotool', 'click', button_code], capture_output=True, timeout=1, text=True)
        if result.returncode != 0:
            print(f"[ERROR CLICK] code={result.returncode}: {result.stderr.strip()}")
        else:
            print(f'[CLICK] Click {button} realizado')
    except Exception as e:
        print(f'[ERROR CLICK] {e}')

@socketio.on('action_button')
def handle_action_button(data):
    """Botones de acción personalizables (L1/L2)"""
    try:
        button = data.get('button', 'L1')
        # Keycodes Linux input-event-codes.h
        # Enter=28, Esc=1
        action_map = {
            'L1': ['28:1', '28:0'],  # Enter
            'L2': ['1:1', '1:0']     # Esc
        }
        key_sequence = action_map.get(button)
        if not key_sequence:
            print(f"[ACTION] Botón desconocido: {button}")
            return

        result = subprocess.run(['ydotool', 'key', *key_sequence], capture_output=True, timeout=1, text=True)
        if result.returncode != 0:
            print(f"[ERROR ACTION_BUTTON] code={result.returncode}: {result.stderr.strip()}")
        else:
            print(f"[ACTION] {button} ejecutado")
    except Exception as e:
        print(f'[ERROR ACTION_BUTTON] {e}')

@socketio.on('type_text')
def handle_type_text(data):
    """Escribe texto remoto usando ydotool"""
    try:
        text = str(data.get('text', ''))[:220]
        if not text.strip():
            return

        result = subprocess.run(['ydotool', 'type', '--', text], capture_output=True, timeout=2, text=True)
        if result.returncode != 0:
            print(f"[ERROR TYPE_TEXT] code={result.returncode}: {result.stderr.strip()}")
        else:
            print(f"[TYPE_TEXT] texto enviado ({len(text)} chars)")
    except Exception as e:
        print(f'[ERROR TYPE_TEXT] {e}')

# Keycodes evdev/Linux para teclas especiales (ydotool key <code>:1 <code>:0)
TYPE_CHAR_KEYCODES = {
    'BackSpace': 14,
    'Return': 28,
    'Enter': 28,
    'Tab': 15,
    'Escape': 1,
    'ArrowLeft': 105,
    'ArrowRight': 106,
    'ArrowUp': 103,
    'ArrowDown': 108,
}


def _send_keycode(code, name):
    """Envía una tecla especial por su keycode y registra el resultado."""
    result = subprocess.run(
        ['ydotool', 'key', f'{code}:1', f'{code}:0'],
        capture_output=True, timeout=1, text=True,
    )
    if result.returncode != 0:
        print(f"[ERROR TYPE_CHAR {name}] code={result.returncode}: {result.stderr.strip()}")
    else:
        print(f"[TYPE_CHAR] {name} enviado")


@socketio.on('type_char')
def handle_type_char(data):
    """Escribe un carácter individual en tiempo real (cada tecla del teclado del teléfono)"""
    try:
        char = str(data.get('char', ''))
        if not char:
            return

        if char in TYPE_CHAR_KEYCODES:
            _send_keycode(TYPE_CHAR_KEYCODES[char], char)
        else:
            if len(char) > 8:
                return
            result = subprocess.run(
                ['ydotool', 'type', '--', char],
                capture_output=True, timeout=1, text=True,
            )
            if result.returncode != 0:
                print(f"[ERROR TYPE_CHAR] code={result.returncode}: {result.stderr.strip()}")
            else:
                print(f"[TYPE_CHAR] '{char}' enviado")
    except Exception as e:
        print(f'[ERROR TYPE_CHAR] {e}')

@socketio.on('double_click')
def handle_double_click(data):
    """Realiza un doble click izquierdo"""
    try:
        result = subprocess.run(['ydotool', 'click', '--repeat=2', '0xC0'], capture_output=True, timeout=1, text=True)
        if result.returncode != 0:
            print(f"[ERROR DOUBLE_CLICK] code={result.returncode}: {result.stderr.strip()}")
        else:
            print('[DOUBLE_CLICK] Doble click realizado')
    except Exception as e:
        print(f'[ERROR DOUBLE_CLICK] {e}')

@socketio.on('scroll')
def handle_scroll(data):
    """Realiza scroll con rueda"""
    try:
        direction = data.get('direction', 'up')
        clicks = int(data.get('clicks', 3))

        # En ydotool moderno el scroll va por mousemove --wheel
        step = -1 if direction == 'up' else 1
        result = subprocess.run(
            ['ydotool', 'mousemove', '--wheel', '--', '0', str(step * clicks)],
            capture_output=True,
            timeout=1,
            text=True
        )
        if result.returncode != 0:
            print(f"[ERROR SCROLL] code={result.returncode}: {result.stderr.strip()}")
        else:
            print(f'[SCROLL] Scroll {direction} ({clicks})')
    except Exception as e:
        print(f'[ERROR SCROLL] {e}')

@socketio.on('drag_start')
def handle_drag_start(data):
    """Inicia un drag (botón izquierdo down)"""
    global is_dragging, drag_start_x, drag_start_y
    try:
        is_dragging = True
        drag_start_x = data.get('x', 0)
        drag_start_y = data.get('y', 0)
        result = subprocess.run(['ydotool', 'click', '0x40'], capture_output=True, timeout=1, text=True)
        if result.returncode != 0:
            print(f"[ERROR DRAG_START] code={result.returncode}: {result.stderr.strip()}")
        else:
            print('[DRAG] Drag iniciado (botón presionado)')
    except Exception as e:
        print(f'[ERROR DRAG_START] {e}')

@socketio.on('drag_end')
def handle_drag_end(data):
    """Termina un drag (botón izquierdo up)"""
    global is_dragging
    try:
        is_dragging = False
        result = subprocess.run(['ydotool', 'click', '0x80'], capture_output=True, timeout=1, text=True)
        if result.returncode != 0:
            print(f"[ERROR DRAG_END] code={result.returncode}: {result.stderr.strip()}")
        else:
            print('[DRAG] Drag finalizado (botón soltado)')
    except Exception as e:
        print(f'[ERROR DRAG_END] {e}')

if __name__ == '__main__':
    print('Servidor iniciado en http://0.0.0.0:1024')
    print('Asegúrate de que el celular está en la misma red')
    print('Usando ydotool (compatible con Wayland) ✅')
    socketio.run(app, host='0.0.0.0', port=1024, debug=False, allow_unsafe_werkzeug=True)
