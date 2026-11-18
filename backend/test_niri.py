"""
Tests de la integración con niri.

Grupo 1: lógica pura de decisión (niri_command_parts).
Grupo 2: handlers (niri_action / niri_status / niri_workspaces) invocados
         directamente, con `emit` y `subprocess.run` MOCKEADOS, de modo que
         NUNCA se ejecuta niri de verdad (ni siquiera 'quit' cierra tu sesión).

Ningún test de este archivo toca la sesión real de niri ni el mouse/teclado.
"""

import json
import pytest

import server
from server import (
    NIRI_ALLOWED,
    NIRI_PARAM,
    NIRI_SPECIAL,
    NIRI_ENV,
    app,
    socketio,
    niri_command_parts,
)


# ===========================================================================
# GRUPO 1 — niri_command_parts (lógica pura, sin efectos)
# ===========================================================================

# 1.1 Acciones simples permitidas -> ['action', <nombre>]
@pytest.mark.parametrize('action', sorted(NIRI_ALLOWED), ids=sorted(NIRI_ALLOWED))
def test_accion_simple_permitida(action):
    assert niri_command_parts(action) == ['action', action]


# 1.2 Acciones especiales mapeadas a un comando fijo
def test_open_terminal_siempre_kitty():
    assert niri_command_parts('open-terminal') == ['action', 'spawn', '--', 'kitty']


def test_quit_siempre_accion_quit():
    assert niri_command_parts('quit') == ['action', 'quit']


# 1.3 Acciones con parámetro numérico dentro del rango permitido
@pytest.mark.parametrize('action,param', [
    ('focus-workspace', 2),
    ('focus-workspace', 1),
    ('focus-workspace', 40),           # límite superior de NIRI_PARAM
    ('move-window-to-workspace', 1),
    ('move-window-to-workspace', 40),
    ('focus-column', 0),               # límite inferior
    ('focus-column', 100),
    ('move-column-to-index', 0),
    ('move-column-to-index', 100),
])
def test_param_dentro_de_rango(action, param):
    assert niri_command_parts(action, param) == ['action', action, str(param)]


# 1.4 Parámetro inválido -> None (no se devuelve nada ejecutable)
@pytest.mark.parametrize('action,param', [
    ('focus-workspace', 0),            # por debajo del mínimo
    ('focus-workspace', 41),           # por encima del máximo
    ('focus-workspace', 99),
    ('focus-column', -1),
    ('move-column-to-index', 101),
    ('focus-workspace', 'x'),          # no numérico
    ('focus-workspace', '2.5'),        # float inválido
    ('focus-workspace', None),         # sin parámetro
])
def test_param_invalido_rechazado(action, param):
    assert niri_command_parts(action, param) is None


# 1.5 Acciones prohibidas / inyección -> None (nada escapa de la lista)
@pytest.mark.parametrize('action', [
    'spawn',                           # generar procesos arbitrarios
    'close-window; rm -rf /',          # inyección de shell
    'reload-config',                   # no expuesto
    'quit-session',
    '',                                # vacío
    None,                              # sin acción
    123,                               # tipo inesperado
])
def test_accion_prohibida_rechazada(action):
    assert niri_command_parts(action) is None


# 1.6 open-terminal / quit ignoran cualquier parámetro del cliente
#     (el cliente nunca puede cambiar el comando ejecutado)
@pytest.mark.parametrize('param', ['calc', 'bash', None, 999])
def test_open_terminal_ignora_parametro(param):
    assert niri_command_parts('open-terminal', param) == ['action', 'spawn', '--', 'kitty']


def test_quit_ignora_parametro():
    assert niri_command_parts('quit', 'cualquier-cosa') == ['action', 'quit']


# ===========================================================================
# GRUPO 2 — Handlers con emit + subprocess.run MOCKEADOS
# ===========================================================================
@pytest.fixture
def niri_mocks(monkeypatch):
    """Reemplaza emit y subprocess.run por fakes que registran las llamadas.
    Así el handler se ejercita de punta a punta sin ejecutar nada real."""
    emit_calls = []
    run_calls = []

    def fake_emit(name, payload=None, **kwargs):
        emit_calls.append((name, payload))

    class FakeResult:
        returncode = 0
        stdout = ''
        stderr = ''

    def fake_run(cmd, *args, **kwargs):
        run_calls.append({'cmd': list(cmd), 'env': kwargs.get('env')})
        return FakeResult()

    monkeypatch.setattr(server, 'emit', fake_emit)
    monkeypatch.setattr(server.subprocess, 'run', fake_run)
    return emit_calls, run_calls


def test_accion_prohibida_no_ejecuta(niri_mocks):
    """Defensa en profundidad: una acción prohibida jamás llega a subprocess."""
    emit_calls, run_calls = niri_mocks
    server.handle_niri_action({'action': 'spawn', 'param': 'xterm'})
    assert emit_calls == [('niri_result', {'ok': False, 'error': 'acción no permitida'})]
    assert run_calls == []


def test_accion_permitida_se_ejecuta(niri_mocks):
    """Una acción válida sí se ejecuta, con el argv y el env correctos."""
    emit_calls, run_calls = niri_mocks
    server.handle_niri_action({'action': 'close-window'})
    assert emit_calls == [('niri_result', {'ok': True})]
    assert run_calls == [{'cmd': ['niri', 'msg', 'action', 'close-window'], 'env': NIRI_ENV}]


def test_param_fuera_de_rango_rechazado_handler(niri_mocks):
    emit_calls, run_calls = niri_mocks
    server.handle_niri_action({'action': 'focus-workspace', 'param': 99})
    assert emit_calls == [('niri_result', {'ok': False, 'error': 'acción no permitida'})]
    assert run_calls == []


def test_open_terminal_wiring(niri_mocks):
    emit_calls, run_calls = niri_mocks
    server.handle_niri_action({'action': 'open-terminal'})
    assert emit_calls == [('niri_result', {'ok': True})]
    assert run_calls[0]['cmd'] == ['niri', 'msg', 'action', 'spawn', '--', 'kitty']


def test_quit_wiring_sin_ejecutar_real(niri_mocks):
    """Caso peligroso: el handler arma el argv de quit, pero (gracias al mock)
    no llega a cerrar la sesión real del usuario."""
    emit_calls, run_calls = niri_mocks
    server.handle_niri_action({'action': 'quit'})
    assert emit_calls == [('niri_result', {'ok': True})]
    assert run_calls[0]['cmd'] == ['niri', 'msg', 'action', 'quit']


def test_peticion_malformada_no_crashea(niri_mocks):
    emit_calls, run_calls = niri_mocks
    server.handle_niri_action('no-es-un-dict')
    assert emit_calls == [('niri_result', {'ok': False, 'error': 'petición inválida'})]
    assert run_calls == []


def test_niri_status_disponible(monkeypatch):
    monkeypatch.setattr(server, 'niri_available', lambda: True)
    assert server.handle_niri_status() == {'available': True}


def test_niri_status_no_disponible(monkeypatch):
    monkeypatch.setattr(server, 'niri_available', lambda: False)
    assert server.handle_niri_status() == {'available': False}


def test_niri_workspaces_parsea(monkeypatch):
    raw = json.dumps([
        {'id': 1, 'idx': 1, 'name': None, 'is_active': True,
         'is_focused': True, 'output': 'LVDS-1'},
        {'id': 2, 'idx': 2, 'name': 'Dev', 'is_active': False,
         'is_focused': False, 'output': 'LVDS-1'},
    ])

    class FakeRes:
        returncode = 0
        stdout = raw
        stderr = ''

    monkeypatch.setattr(server.subprocess, 'run', lambda *a, **k: FakeRes())
    res = server.handle_niri_workspaces()
    assert res['ok'] is True
    ws = res['workspaces']
    assert ws[0] == {'id': 1, 'idx': 1, 'name': None, 'active': True,
                     'focused': True, 'output': 'LVDS-1'}
    assert ws[1]['name'] == 'Dev'


def test_niri_workspaces_falla_returncode(monkeypatch):
    class FakeRes:
        returncode = 1
        stdout = ''
        stderr = 'boom'

    monkeypatch.setattr(server.subprocess, 'run', lambda *a, **k: FakeRes())
    assert server.handle_niri_workspaces() == {'ok': False}


def test_niri_workspaces_json_corrupto(monkeypatch):
    class FakeRes:
        returncode = 0
        stdout = 'esto no es json'
        stderr = ''

    monkeypatch.setattr(server.subprocess, 'run', lambda *a, **k: FakeRes())
    res = server.handle_niri_workspaces()
    assert res['ok'] is False
    assert 'error' in res


# ===========================================================================
# GRUPO 5 — Integración real (SOLO LECTURA), opcional y automáticamente
#           omitida si no hay niri en el entorno. No ejecuta ninguna acción
#           que modifique la sesión: solo consulta estado y escritorios.
# ===========================================================================
@pytest.mark.skipif(not server.niri_available(),
                    reason="niri no disponible en este entorno")
def test_integracion_real_solo_lectura():
    # Estado real del compositor
    status = server.handle_niri_status()
    assert status == {'available': True}

    # Lectura real de escritorios (comando -j workspaces, no modifica nada)
    ws = server.handle_niri_workspaces()
    assert ws['ok'] is True
    assert isinstance(ws['workspaces'], list)
    assert len(ws['workspaces']) >= 1

    primero = ws['workspaces'][0]
    assert set(['id', 'idx', 'name', 'active', 'focused', 'output']).issubset(primero)
    # Al menos un escritorio debe estar activo/focused
    assert any(w['active'] or w['focused'] for w in ws['workspaces'])
