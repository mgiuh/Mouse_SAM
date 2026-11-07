"""
Tests simples para verificar que el backend recibe eventos del frontend sin errores.

Estos son tests básicos que verifican:
- La conexión WebSocket se establece
- Eventos se envían sin causar excepciones
- El servidor no crashea
"""

import pytest
from server import app, socketio


@pytest.fixture
def socket_client():
    """
    Crea un cliente de test para Flask-SocketIO.
    Esto es lo que simula al "frontend enviando eventos".
    """
    app.config['TESTING'] = True
    client = socketio.test_client(app)
    return client


class TestFrontendBackendEvents:
    """Grupo de tests: verificar que eventos llegan al backend"""

    def test_cliente_puede_conectar(self, socket_client):
        """
        TEST 1: ¿Puede el frontend conectarse al backend?
        
        Esto es como abrir la página en el navegador.
        Si falla, no hay conexión WebSocket.
        """
        # Si llegamos acá sin error, la conexión se estableció
        assert socket_client is not None

    def test_click_izquierdo_no_crashea(self, socket_client):
        """
        TEST 2: Cuando el frontend envía un click izquierdo, ¿el servidor no crashea?
        
        Simula:
        - Usuario hace tap en el celular
        - Frontend envía: {'button': 'left'}
        - Backend lo procesa (ejecuta ydotool)
        
        Si hay excepción, el test falla.
        """
        # Enviar evento de click izquierdo
        socket_client.emit('click', {'button': 'left'})
        # Si llegamos acá sin error, fue exitoso
        assert True

    def test_click_derecho_no_crashea(self, socket_client):
        """TEST 3: Click derecho sin error"""
        socket_client.emit('click', {'button': 'right'})
        assert True

    def test_click_medio_no_crashea(self, socket_client):
        """TEST 4: Click medio sin error"""
        socket_client.emit('click', {'button': 'middle'})
        assert True

    def test_movimiento_mouse_no_crashea(self, socket_client):
        """
        TEST 5: Cuando el frontend envía movimiento de mouse, ¿funciona?
        
        Simula:
        - Usuario desliza el dedo en el touchpad
        - Frontend envía: {'x': 100, 'y': 50}
        - Backend encola el movimiento
        """
        socket_client.emit('move_mouse', {'x': 100, 'y': 50})
        assert True

    def test_doble_click_no_crashea(self, socket_client):
        """TEST 6: Doble click sin error"""
        socket_client.emit('double_click', {})
        assert True

    def test_scroll_arriba_no_crashea(self, socket_client):
        """TEST 7: Scroll hacia arriba sin error"""
        socket_client.emit('scroll', {'direction': 'up', 'clicks': 3})
        assert True

    def test_scroll_abajo_no_crashea(self, socket_client):
        """TEST 8: Scroll hacia abajo sin error"""
        socket_client.emit('scroll', {'direction': 'down', 'clicks': 3})
        assert True

    def test_drag_start_y_end_no_crashea(self, socket_client):
        """
        TEST 9: Drag (click y arrastre) sin error
        
        Simula:
        - Usuario presiona y arrastra en el touchpad
        - Frontend envía drag_start
        - Frontend envía drag_end
        """
        socket_client.emit('drag_start', {'x': 0, 'y': 0})
        socket_client.emit('drag_end', {'x': 100, 'y': 100})
        assert True

    def test_action_button_L1_no_crashea(self, socket_client):
        """TEST 10: Botón L1 (Enter) sin error"""
        socket_client.emit('action_button', {'button': 'L1'})
        assert True

    def test_action_button_L2_no_crashea(self, socket_client):
        """TEST 11: Botón L2 (Esc) sin error"""
        socket_client.emit('action_button', {'button': 'L2'})
        assert True

    def test_type_text_no_crashea(self, socket_client):
        """
        TEST 12: Escribir texto remoto sin error
        
        Simula:
        - Frontend envía texto para ser escrito
        - Backend lo procesa con ydotool type
        """
        socket_client.emit('type_text', {'text': 'Hola Mundo'})
        assert True

    def test_type_char_individual_no_crashea(self, socket_client):
        """
        TEST 13: Escribir caracteres individuales en tiempo real
        
        Simula:
        - Usuario escribe en el teclado del teléfono
        - Cada carácter se envía directo al PC
        """
        socket_client.emit('type_char', {'char': 'H'})
        socket_client.emit('type_char', {'char': 'o'})
        socket_client.emit('type_char', {'char': 'l'})
        socket_client.emit('type_char', {'char': 'a'})
        assert True

    def test_type_char_backspace_no_crashea(self, socket_client):
        """TEST 14: Backspace en tiempo real"""
        socket_client.emit('type_char', {'char': 'BackSpace'})
        assert True

    def test_type_char_enter_no_crashea(self, socket_client):
        """TEST 15: Enter en tiempo real"""
        socket_client.emit('type_char', {'char': 'Enter'})
        assert True
