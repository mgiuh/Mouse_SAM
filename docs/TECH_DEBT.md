# Deuda técnica de SAMPC

Registro de lo que queda pendiente, lo opcional y lo descartado, para
retomar en futuras sesiones sin reconstruir contexto.

## Pendiente
1. **Chips de escritorio "en vivo"** en el panel de niri. Se actualizan al abrir
   el panel o al cambiar a la pestaña Escritorios; no se refrescan solos cuando
   se cambia de escritorio en la PC. Pulido, no bloqueante.

## Opcionales
2. **`touchmove` sin throttle en el cliente** (`frontend/script.js`): el celular
   emite un evento por cada movimiento del dedo. El lag del panel ya se corrigió
   (era `backdrop-filter`), pero por red convendría agrupar los envíos con
   `requestAnimationFrame` o un debounce.

## Descartado
- **Giroscopio / sensores de orientación**: requieren contexto seguro (HTTPS o
  `localhost` vía `adb reverse`) y no se habían definido los gestos deseados.
  Se descartó por ahora.

## Hecho (sesiones recientes)
- **Firewall en `start.sh`**: detecta `ufw`/`firewalld` activos y ofrece abrir el
  puerto 1024 con 3 opciones (solo LAN / cualquier red / omitir; default solo
  LAN). Idempotente (no pregunta si ya hay regla o no hay firewall); sin TTY no
  toca reglas. Reglas LAN restringidas a los subnets RFC1918 detectados con
  `ip -o -f inet addr show` (red enmascarada + deduplicada). firewalld usa
  rich rules permanentes + `--reload`; todo vía `ensure_sudo` y con fallos no
  fatales (`warn`, nunca `die`).
- **sudo diferido en `start.sh`**: se pide solo cuando un paso privilegiado lo
  requiere (ydotool, udev, grupo input, firewall).
- **`test_events.py` ya no dispara ydotool real**: fixture `autouse` mockea
  `server.subprocess.run` (mismo módulo que usa el worker de movimiento), así
  que correr `pytest` no mueve el mouse ni escribe en el teclado. El falso
  registra las órdenes armadas para que los tests sigan siendo útiles.
- **Panel de teclado remoto (tecla por tecla)**: botón **⌨️** que abre un panel
  con campo capturador y 8 teclas especiales; cada pulsación emite `type_char`
  al instante. Backend: `TYPE_CHAR_KEYCODES` + `_send_keycode` en `server.py`
  (BackSpace 14, Return 28, Tab 15, Escape 1, flechas 105/106/103/108).
  Frontend: captura vía **`beforeinput`** (`e.data`) porque los teclados
  táctiles de Android/Chrome no emiten `keydown` fiable; borrado → `BackSpace`,
  textos multi-carácter (swipe/autocorrección) se envían carácter por carácter
  con 12 ms de separación; `keydown` queda solo como fallback de PC con
  protección anti-duplicados (50 ms). Cubierto por 11 tests nuevos en
  `test_events.py`.
- **Limpieza de tests**: se eliminaron 2 pruebas que no aportaban —
  `test_enter_usa_keycode_28` (duplicaba Return, mismo keycode 28) y
  `test_integracion_real_solo_lectura` (contactaba niri real).

## Estado actual de la batería
- `test_niri.py` (70) + `test_events.py` (26) = **96 tests en verde**, todos
  con ydotool mockeado (sin efectos en el equipo).

## Estado del proyecto (referencia rápida)
- Panel de niri con 4 pestañas + fila fija, altura fija `50dvh`.
- Lag del móvil corregido (sin `backdrop-filter` en botones/hoja del panel).
- Backend niri con lista cerrada de acciones; `open-terminal` fijo a `kitty`.
- Panel de teclado remoto: botón ⌨️, envío tecla por tecla vía `type_char`;
  8 teclas especiales; campo capturador (se limpia tras cada tecla).
- Tests: `backend/test_niri.py` (70) + `backend/test_events.py` (26) = 96 en verde;
  ambos con ydotool mockeado (sin efectos en el equipo).
- Servidor en `0.0.0.0:1024`; Flask cachea `index.html` (reiniciar al editarlo).
