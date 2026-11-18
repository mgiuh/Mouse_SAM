# 🖱️ SAMPC - Touchpad Remoto

Control el cursor de tu PC Linux desde un celular usando un touchpad virtual en el navegador web.

## 📌 Estado actual (cambios de la sesión reciente)

Esto es lo que se agregó/modificó y conviene saber antes de retomar:

- **Panel de niri (compositor Wayland)**: el botón **▦** de la barra abre un panel con
  **4 pestañas de categoría** (Ventana / Columnas / Monitores / Escritorios); al tocar una
  solo muestra sus acciones. Debajo hay una **fila fija** siempre visible con Kitty, Captura,
  Overview y Salir (este último pide confirmación). Altura fija de `50dvh`; el cuerpo scrollea
  y el footer queda fijo.
- **Rendimiento en móvil**: el lag del panel al desplazarse se corrigió **quitando
  `backdrop-filter` de los botones y de la hoja del panel** (no era la cantidad de botones).
- **Socket.IO** se sirve localmente desde `frontend/vendor/socket.io.min.js` (sin CDN externo).
  El server manda headers anti-caché en HTML/CSS/JS.
- **Backend niri**: lista cerrada de acciones permitidas (seguridad); `open-terminal` está fijo a
  `kitty`. Los tests en `backend/test_niri.py` (71 en verde) cubren la lista cerrada y los
  handlers con `subprocess.run` mockeado (incluido `quit`, sin ejecutar la sesión real).
- **Gotcha de desarrollo**: `server.py` corre con `debug=False`, por lo que **Flask cachea la
  plantilla `index.html`**. Tras editar el HTML hay que **reiniciar el server** para ver los
  cambios; los CSS/JS estáticos sí se releen solos.
- **Servidor**: escucha en `0.0.0.0:1024`. Para funciones que exigen contexto seguro (ej.
  sensores del celular) haría falta HTTPS o `localhost` vía `adb reverse` — no implementado.

## 📋 Requisitos

- **PC Principal (Servidor)**: Linux con sesión Wayland (probado en Arch Linux) y Python 3.9+
- **ydotool**: `start.sh` lo instala automáticamente (Arch, Fedora, Debian/Ubuntu si está en los repos, openSUSE)
- **Celular/Dispositivo (Cliente)**: Navegador web moderno
- **Red**: Ambos dispositivos en la misma red local o accesible por IP (puerto 1024)

## 🚀 Instalación

La forma recomendada es usar el script de arranque, que prepara todo:

```bash
cd Mouse_SAM
./start.sh
```

El script se encarga de:

1. Crear el entorno virtual e instalar las dependencias Python.
2. Instalar `ydotool` si no está presente.
3. Configurar `/dev/uinput` (regla udev + grupo `input`).
4. Configurar `ydotoold` como servicio de usuario de systemd.
   - Si tu usuario recién se agregó al grupo `input`, usa un daemon temporal
     como root y te avisa que cierres sesión para el modo permanente.
5. Verificar que `ydotool` responda antes de arrancar el servidor.

Deberías ver algo como:
```
Servidor iniciado en http://0.0.0.0:1024
Asegúrate de que el celular está en la misma red
```

### Instalación manual (opcional)

```bash
cd backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Instalar y configurar ydotool según tu distro
sudo pacman -S ydotool          # Arch
sudo usermod -aG input "$USER"  # requiere cerrar y abrir sesión
systemctl --user enable --now ydotool.service

python3 server.py
```

### Acceder desde el celular

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

## 🪟 Panel de acciones niri (compositor niri)

Si tu PC usa el compositor **niri** (Wayland), la barra superior del celular
muestra un botón **▦** que abre un panel deslizante con acciones del
escritorio. El botón solo aparece si se detecta niri al conectar
(`NIRI_SOCKET` o buscándolo en `/run/user/<uid>/niri.*.sock`).

> ⚠️ El botón **"Salir de la sesión"** cierra niri de verdad (termina tu
> sesión gráfica). Pide confirmación antes de ejecutarse; usalo con cuidado.

### Secciones del panel
- **Ventana**: cerrar, pantalla completa, centrar, flotante, ventana previa.
- **Columnas**: mover el foco entre columnas, mover columnas, plegado en
  pestañas, meter/sacar ventanas de una columna.
- **Monitores**: cambiar el foco entre monitores (izq/der/arriba/abajo).
- **Escritorios**: anterior/siguiente escritorio, + chips numerados que leen
  tus escritorios reales (el activo se resalta en celeste). Tocar un chip
  salta a ese escritorio.
- **Abrir**: *Terminal (Kitty)* abre una terminal Kitty.
- **Sistema**: captura de pantalla/ventana, overview, atajos y salir de la
  sesión.

### Seguridad
El celular **no puede ejecutar comandos libres**. El servidor solo obedece
una lista cerrada de identificadores (`backend/server.py`: `NIRI_ALLOWED`,
`NIRI_PARAM`, `NIRI_SPECIAL`). Cualquier otra acción —incluido `spawn`
genérico— se rechaza **antes** de ejecutar algo, y los parámetros de
escritorio se validan contra un rango. Verificado por `backend/test_niri.py`.

### Cambiar la app de "Terminal"
La acción `open-terminal` está fijada a `kitty` en el servidor. Para usar otra
app, editá la entrada en `NIRI_SPECIAL` de `backend/server.py`:

```python
NIRI_SPECIAL = {
    'open-terminal': ['action', 'spawn', '--', 'kitty'],  # cambiá 'kitty' por tu app
    'quit': ['action', 'quit'],
}
```

Luego reiniciá el servidor.

## 🔧 Estructura del Proyecto

```
SAMPC/
├── start.sh              # Instala dependencias, configura ydotool y arranca
├── backend/
│   ├── server.py           # Servidor Flask + SocketIO (control vía ydotool + niri)
│   ├── server_simple.py    # Versión legacy de referencia
│   ├── test_events.py      # Tests de humo de los eventos Socket.IO
│   ├── test_niri.py         # Tests de la integración con niri (lista cerrada + handlers)
│   └── requirements.txt     # Dependencias de Python
└── frontend/
    ├── index.html          # Página HTML
    ├── styles.css          # Estilos (Dark/Glass)
    ├── script.js           # Lógica del touchpad + panel niri
    └── vendor/
        └── socket.io.min.js # Cliente Socket.IO servido localmente
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
- Verificá que `ydotoold` esté corriendo:
  ```bash
  systemctl --user status ydotool.service
  ydotool mousemove -- 0 0
  ```
- Asegurate de que tu usuario esté en el grupo `input` y de haber cerrado
  sesión una vez después de agregarlo:
  ```bash
  id -nG | grep input
  ls -l /dev/uinput
  ```
- Si `/dev/uinput` no está en grupo `input` con modo `0660`, recreá la regla udev:
  ```bash
  echo 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' \
    | sudo tee /etc/udev/rules.d/80-uinput.rules
  sudo udevadm control --reload-rules
  sudo udevadm trigger --name-match=uinput
  ```
- Revisá los logs del daemon: `journalctl --user -u ydotool -n 50`.

### El touchpad se siente lento
- Verifica la conexión de red
- Revisa que `ydotoold` esté activo (el servidor encola y agrupa los movimientos)

## 🎨 Personalización

Puedes modificar fácilmente:

- **Sensibilidad del cursor**: En `script.js`, cambia los valores de `deltaX` y `deltaY`
- **Tiempo de long press**: En `script.js`, cambia `LONG_PRESS_DURATION`
- **Diseño**: Modifica `styles.css` a tu gusto
- **Comandos del servidor**: Edita `server.py` para agregar más funcionalidades

## 📝 Notas

- El proyecto usa WebSockets para comunicación en tiempo real
- ydotool controla el mouse y el teclado del sistema operativo (compatible con Wayland)
- No hay autenticación (úsalo en redes confiables)
- El servidor escucha en `0.0.0.0:1024` (accesible desde cualquier dispositivo en la red)

## 🚀 Próximas mejoras posibles

- [x] Controlar teclado (escritura en tiempo real)
- [x] Panel de acciones para el compositor niri (lista cerrada de acciones)
- [ ] Capturar pantalla remota
- [ ] Autenticación por PIN
- [ ] Múltiples sesiones simultáneas
- [ ] Interfaz móvil nativa
- [ ] Soporte para gestos avanzados (pinch, swipe)

---

**Autor**: SAMPC Project
**Licencia**: MIT
