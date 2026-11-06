from flask import Flask, render_template
from flask_socketio import SocketIO, emit
import subprocess
import time
import sys

app = Flask(__name__, static_folder='../frontend', static_url_path='', template_folder='../frontend')
socketio = SocketIO(app, cors_allowed_origins="*", ping_timeout=60, ping_interval=25)

# Iniciar ydotoold
subprocess.Popen(['sudo', 'ydotoold'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
time.sleep(1)
print('[✅ YDOTOOLD] Iniciado', flush=True)

@app.route('/')
def index():
    return render_template('index.html')

@socketio.on('connect')
def on_connect():
    print('\n✅ CLIENTE CONECTADO', flush=True)
    sys.stdout.flush()

@socketio.on('move_mouse')
def on_move_mouse(data):
    print(f'[RECIBIDO] move_mouse: {data}', flush=True)
    sys.stdout.flush()
    try:
        x = int(round(data.get('x', 0)))
        y = int(round(data.get('y', 0)))
        result = subprocess.run(['ydotool', 'mousemove', str(x), str(y)], capture_output=True, timeout=1)
        print(f'[MOVE] ({x}, {y}) - return code: {result.returncode}', flush=True)
    except Exception as e:
        print(f'[ERROR] {e}', flush=True)

@socketio.on('click')
def on_click(data):
    print(f'[CLICK] recibido', flush=True)
    try:
        button = {'left': '1', 'right': '3'}.get(data.get('button'), '1')
        subprocess.run(['ydotool', 'click', button], capture_output=True, timeout=1)
        print(f'[CLICK] {data.get("button")} - OK', flush=True)
    except Exception as e:
        print(f'[ERROR CLICK] {e}', flush=True)

if __name__ == '__main__':
    print('Servidor en http://0.0.0.0:1024', flush=True)
    socketio.run(app, host='0.0.0.0', port=1024, allow_unsafe_werkzeug=True, debug=False)
