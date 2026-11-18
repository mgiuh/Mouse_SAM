# Deuda técnica de SAMPC

Registro de lo que queda pendiente, lo opcional y lo descartado, para
retomar en futuras sesiones sin reconstruir contexto.

## Pendiente
1. **Firewall en `start.sh`** (requisito original, aún no implementado).
   - Detectar `ufw` / `firewalld` activos y ofrecer abrir el puerto 1024 con un
     menú de 3 opciones: solo LAN / cualquier red / omitir.
   - Hoy el README explica el firewall, pero el script no lo configura.
2. **Chips de escritorio "en vivo"** en el panel de niri. Se actualizan al abrir
   el panel o al cambiar a la pestaña Escritorios; no se refrescan solos cuando
   se cambia de escritorio en la PC. Pulido, no bloqueante.

## Opcionales
3. **`test_events.py` dispara `ydotool` real** al correrse (mueve el mouse y
   escribe en el teclado del PC). Conviene mockearlo como se hizo con los tests
   de niri, para que correr `pytest` no tenga efectos secundarios en el equipo.
4. **`touchmove` sin throttle en el cliente** (`frontend/script.js`): el celular
   emite un evento por cada movimiento del dedo. El lag del panel ya se corrigió
   (era `backdrop-filter`), pero por red convendría agrupar los envíos con
   `requestAnimationFrame` o un debounce.

## Descartado
- **Giroscopio / sensores de orientación**: requieren contexto seguro (HTTPS o
  `localhost` vía `adb reverse`) y no se habían definido los gestos deseados.
  Se descartó por ahora.

## Estado del proyecto (referencia rápida)
- Panel de niri con 4 pestañas + fila fija, altura fija `50dvh`.
- Lag del móvil corregido (sin `backdrop-filter` en botones/hoja del panel).
- Backend niri con lista cerrada de acciones; `open-terminal` fijo a `kitty`.
- Tests de niri en `backend/test_niri.py` (71 en verde).
- Servidor en `0.0.0.0:1024`; Flask cachea `index.html` (reiniciar al editarlo).
