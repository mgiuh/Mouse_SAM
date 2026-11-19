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
  registra las órdenes armadas para que los tests sigan siendo útiles. Batería
  completa: 86 tests en verde.

## Estado del proyecto (referencia rápida)
- Panel de niri con 4 pestañas + fila fija, altura fija `50dvh`.
- Lag del móvil corregido (sin `backdrop-filter` en botones/hoja del panel).
- Backend niri con lista cerrada de acciones; `open-terminal` fijo a `kitty`.
- Tests: `backend/test_niri.py` (71) + `backend/test_events.py` (15) = 86 en verde;
  ambos con ydotool mockeado (sin efectos en el equipo).
- Servidor en `0.0.0.0:1024`; Flask cachea `index.html` (reiniciar al editarlo).
