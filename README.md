# 🖱️ SAMPC - Touchpad Remoto

Control el cursor de tu PC Linux desde un celular usando un touchpad virtual en el navegador web.

## 📋 Requisitos

- **PC Principal (Servidor)**: Linux con Python 3.7+
- **Celular/Dispositivo (Cliente)**: Navegador web moderno
- **Red**: Ambos dispositivos en la misma red local o accesible por IP (puerto 1024)

## 🚀 Instalación

### 1. Backend (PC Principal - Linux)

```bash
# Ir a la carpeta del backend
cd backend

# Crear un entorno virtual (recomendado)
python3 -m venv venv
source venv/bin/activate

# Instalar dependencias
pip install -r requirements.txt
```

### 2. Ejecutar el servidor

```bash
python3 server.py
```

Deberías ver algo como:
```
Servidor iniciado en http://0.0.0.0:5000
Asegúrate de que el celular está en la misma red
```

### 3. Acceder desde el celular

1. En tu celular, abre el navegador
2. Ingresa la IP de tu PC + puerto 1024, ej: `http://192.168.x.x:1024`
3. ¡Listo! Debería conectarse automáticamente

## 🎮 Cómo Usar

### Controles del Touchpad

| Gesto | Acción |
|-------|--------|
| **Arrastra** | Mueve el cursor |
| **Tap** (toque rápido) | Click izquierdo |
| **Doble tap** | Click derecho |
| **Toca y mantén + arrastra** | Drag/Arrastrar |

### Botones de Control

- **Click Izquierdo**: Simula un click izquierdo
- **Click Derecho**: Simula un click derecho (menú contextual)
- **Scroll Arriba/Abajo**: Desplaza verticalmente

## 🔧 Estructura del Proyecto

```
SAMPC/
├── backend/
│   ├── server.py           # Servidor Flask + SocketIO
│   └── requirements.txt     # Dependencias de Python
└── frontend/
    ├── index.html          # Página HTML
    ├── styles.css          # Estilos
    └── script.js           # Lógica del touchpad
```

## 📱 Encontrar la IP de tu PC

### En Linux:
```bash
# Opción 1
hostname -I

# Opción 2
ip addr show

# Opción 3
ifconfig
```

Busca algo como `192.168.x.x` o `10.0.x.x`

## 🐛 Solución de Problemas

### "Conexión rechazada"
- Asegúrate de que el servidor esté corriendo
- Verifica que ambos dispositivos estén en la misma red
- Intenta con la IP en lugar de `localhost`

### El cursor no se mueve
- Verifica que pyautogui tenga permisos en Linux
- En algunos sistemas puede requerir: `sudo python3 server.py`

### El touchpad se siente lento
- Intenta reducir el `pyautogui.PAUSE` en `server.py`
- Verifica la conexión de red

## 🎨 Personalización

Puedes modificar fácilmente:

- **Sensibilidad del cursor**: En `script.js`, cambia los valores de `deltaX` y `deltaY`
- **Tiempo de long press**: En `script.js`, cambia `LONG_PRESS_DURATION`
- **Diseño**: Modifica `styles.css` a tu gusto
- **Comandos del servidor**: Edita `server.py` para agregar más funcionalidades

## 📝 Notas

- El proyecto usa WebSockets para comunicación en tiempo real
- pyautogui controla el mouse del sistema operativo
- No hay autenticación (úsalo en redes confiables)
- El servidor escucha en `0.0.0.0:1024` (accesible desde cualquier dispositivo en la red)

## 🚀 Próximas mejoras posibles

- [ ] Controlar teclado
- [ ] Capturar pantalla remota
- [ ] Autenticación por PIN
- [ ] Múltiples sesiones simultáneas
- [ ] Interfaz móvil nativa
- [ ] Soporte para gestos avanzados (pinch, swipe)

---

**Autor**: SAMPC Project
**Licencia**: MIT
