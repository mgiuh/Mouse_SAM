const socket = io({ transports: ['websocket'] });

const touchpad = document.getElementById('touchpad');
const statusEl = document.getElementById('status');
const modeIndicatorEl = document.getElementById('mode-indicator');
const btnMode = document.getElementById('btn-mode-toggle');
const btnLeft = document.getElementById('btn-left-click');
const btnRight = document.getElementById('btn-right-click');
const btnL1 = document.getElementById('btn-l1');
const btnL2 = document.getElementById('btn-l2');
const btnFullscreen = document.getElementById('btn-fullscreen');
const statusTextEl = document.getElementById('status-text');
const appShell = document.querySelector('.app-shell');

const LONG_PRESS_DURATION = 500;
const DOUBLE_TAP_WINDOW = 300;
const DOUBLE_TAP_DISTANCE = 50;
const SCROLL_STEP_PX = 22;

let isConnected = false;
let mode = 'cursor'; // cursor | scroll
let isTouchDevice = false;
let isTouching = false;
let isDragging = false;
let hasMoved = false;
let touchStartTime = 0;
let lastX = 0;
let lastY = 0;
let touchStartX = 0;
let touchStartY = 0;
let longPressTimeout = null;
let pendingSingleTapTimeout = null;
let lastTapTime = 0;
let lastTapX = 0;
let lastTapY = 0;
let accumulatedScrollY = 0;

// ==================== Conexión ====================
socket.on('connect', () => {
    isConnected = true;
    statusTextEl.textContent = 'Conectado ✓';
    statusEl.classList.remove('disconnected');
    statusEl.classList.add('connected');
    appShell.classList.remove('is-disconnected');
});

socket.on('disconnect', () => {
    isConnected = false;
    statusTextEl.textContent = 'Desconectado ✗';
    statusEl.classList.remove('connected');
    statusEl.classList.add('disconnected');
    appShell.classList.add('is-disconnected');
});

socket.on('response', (data) => {
    if (data?.data) console.log('Servidor:', data.data);
});

// ==================== Helpers ====================
function updateModeUI() {
    document.body.dataset.mode = mode;
    if (mode === 'cursor') {
        modeIndicatorEl.textContent = 'CURSOR';
        btnMode.textContent = '🖱️';
        btnMode.title = 'Cambiar a modo scroll';
    } else {
        modeIndicatorEl.textContent = 'SCROLL';
        btnMode.textContent = '🧭';
        btnMode.title = 'Cambiar a modo cursor';
    }
}

function getPointFromEvent(e) {
    const point = e.touches ? e.touches[0] : e;
    return {
        x: point.pageX !== undefined ? point.pageX : point.clientX,
        y: point.pageY !== undefined ? point.pageY : point.clientY
    };
}

function sendClick(button) {
    if (!isConnected) return;
    vibrate(12);
    socket.emit('click', { button });
}

function sendActionButton(button) {
    if (!isConnected) return;
    vibrate(12);
    socket.emit('action_button', { button });
}

function vibrate(ms) {
    if (typeof navigator !== 'undefined' && navigator.vibrate) {
        try { navigator.vibrate(ms); } catch (_) { /* noop */ }
    }
}

function spawnRipple(clientX, clientY) {
    if (typeof clientX !== 'number') return;
    const rect = touchpad.getBoundingClientRect();
    const size = Math.max(rect.width, rect.height) * 0.45;
    const ripple = document.createElement('span');
    ripple.className = 'ripple';
    ripple.style.width = ripple.style.height = size + 'px';
    ripple.style.left = (clientX - rect.left - size / 2) + 'px';
    ripple.style.top = (clientY - rect.top - size / 2) + 'px';
    touchpad.appendChild(ripple);
    ripple.addEventListener('animationend', () => ripple.remove());
}

// ==================== Touchpad events ====================
function handleTouchStart(e) {
    if (!isConnected) return;
    e.preventDefault();

    isTouching = true;
    hasMoved = false;
    touchStartTime = Date.now();

    const src = e.touches ? e.touches[0] : e;
    if (src && typeof src.clientX === 'number') {
        spawnRipple(src.clientX, src.clientY);
        vibrate(8);
    }

    const point = getPointFromEvent(e);
    lastX = point.x;
    lastY = point.y;
    touchStartX = point.x;
    touchStartY = point.y;

    if (longPressTimeout) clearTimeout(longPressTimeout);
    longPressTimeout = setTimeout(() => {
        if (isTouching && mode === 'cursor') {
            isDragging = true;
            socket.emit('drag_start', { x: lastX, y: lastY });
        }
    }, LONG_PRESS_DURATION);
}

function handleTouchMove(e) {
    if (!isConnected || !isTouching) return;
    e.preventDefault();

    const point = getPointFromEvent(e);
    const deltaX = point.x - lastX;
    const deltaY = point.y - lastY;

    lastX = point.x;
    lastY = point.y;

    if (Math.hypot(point.x - touchStartX, point.y - touchStartY) > 8) {
        hasMoved = true;
        if (longPressTimeout && !isDragging) {
            clearTimeout(longPressTimeout);
            longPressTimeout = null;
        }
    }

    if (mode === 'scroll') {
        accumulatedScrollY += deltaY;
        while (Math.abs(accumulatedScrollY) >= SCROLL_STEP_PX) {
            const direction = accumulatedScrollY > 0 ? 'down' : 'up';
            socket.emit('scroll', { direction, clicks: 1 });
            accumulatedScrollY += accumulatedScrollY > 0 ? -SCROLL_STEP_PX : SCROLL_STEP_PX;
        }
        return;
    }

    if (Math.abs(deltaX) > 0 || Math.abs(deltaY) > 0) {
        socket.emit('move_mouse', { x: deltaX, y: deltaY });
    }
}

function handleTouchEnd(e) {
    if (!isConnected) return;
    if (e.cancelable) e.preventDefault();

    if (longPressTimeout) {
        clearTimeout(longPressTimeout);
        longPressTimeout = null;
    }

    const touchDuration = Date.now() - touchStartTime;

    if (isDragging) {
        socket.emit('drag_end', {});
        isDragging = false;
    } else if (!hasMoved && touchDuration < 300 && mode === 'cursor') {
        if (e.changedTouches && e.changedTouches.length > 0) {
            const touch = e.changedTouches[0];
            const x = touch.pageX !== undefined ? touch.pageX : touch.clientX;
            const y = touch.pageY !== undefined ? touch.pageY : touch.clientY;
            const now = Date.now();
            const dt = now - lastTapTime;
            const dist = Math.hypot(x - lastTapX, y - lastTapY);

            if (dt < DOUBLE_TAP_WINDOW && dist < DOUBLE_TAP_DISTANCE) {
                if (pendingSingleTapTimeout) {
                    clearTimeout(pendingSingleTapTimeout);
                    pendingSingleTapTimeout = null;
                }
                sendClick('right');
                lastTapTime = 0;
            } else {
                lastTapTime = now;
                lastTapX = x;
                lastTapY = y;

                if (pendingSingleTapTimeout) clearTimeout(pendingSingleTapTimeout);
                pendingSingleTapTimeout = setTimeout(() => {
                    sendClick('left');
                    pendingSingleTapTimeout = null;
                }, DOUBLE_TAP_WINDOW);
            }
        } else {
            sendClick('left');
        }
    }

    isTouching = false;
    accumulatedScrollY = 0;
}

function handleTouchCancel() {
    if (longPressTimeout) {
        clearTimeout(longPressTimeout);
        longPressTimeout = null;
    }
    if (pendingSingleTapTimeout) {
        clearTimeout(pendingSingleTapTimeout);
        pendingSingleTapTimeout = null;
    }
    if (isDragging) {
        socket.emit('drag_end', {});
        isDragging = false;
    }
    isTouching = false;
    accumulatedScrollY = 0;
}

// Touch real
touchpad.addEventListener('touchstart', (e) => {
    e.stopPropagation();
    isTouchDevice = true;
    handleTouchStart(e);
}, { passive: false });

touchpad.addEventListener('touchmove', (e) => {
    e.stopPropagation();
    handleTouchMove(e);
}, { passive: false });
touchpad.addEventListener('touchend', (e) => {
    e.stopPropagation();
    handleTouchEnd(e);
}, { passive: false });
touchpad.addEventListener('touchcancel', (e) => {
    e.stopPropagation();
    handleTouchCancel(e);
}, { passive: false });

// Fallback mouse en PC
touchpad.addEventListener('mousedown', (e) => {
    if (isTouchDevice) return;
    handleTouchStart(e);
});
touchpad.addEventListener('mousemove', (e) => {
    if (isTouchDevice) return;
    handleTouchMove(e);
});
touchpad.addEventListener('mouseup', (e) => {
    if (isTouchDevice) return;
    handleTouchEnd(e);
});
touchpad.addEventListener('mouseleave', (e) => {
    if (isTouchDevice) return;
    if (isTouching) handleTouchEnd(e);
});

// ==================== Botones ====================
btnMode.addEventListener('click', () => {
    mode = mode === 'cursor' ? 'scroll' : 'cursor';
    updateModeUI();
});

btnLeft.addEventListener('click', () => sendClick('left'));
btnRight.addEventListener('click', () => sendClick('right'));

btnL1.addEventListener('click', () => sendActionButton('L1'));
btnL2.addEventListener('click', () => sendActionButton('L2'));

// ==================== Pantalla completa ====================
btnFullscreen.addEventListener('click', () => {
    if (!document.fullscreenElement) {
        document.documentElement.requestFullscreen().catch(err => {
            console.warn('Fullscreen no disponible:', err.message);
        });
    } else {
        document.exitFullscreen();
    }
});

// ==================== Acciones niri ====================
const btnNiri = document.getElementById('btn-niri');
const niriOverlay = document.getElementById('niri-overlay');
const niriClose = document.getElementById('niri-close');
const niriWorkspaces = document.getElementById('niri-workspaces');
const niriConfirm = document.getElementById('niri-confirm');
const niriConfirmYes = document.getElementById('niri-confirm-yes');
const niriConfirmNo = document.getElementById('niri-confirm-no');
let niriAvailable = false;

function openNiriPanel() {
    if (!niriAvailable) return;
    loadNiriWorkspaces();
    niriOverlay.hidden = false;
}

function closeNiriPanel() {
    niriOverlay.hidden = true;
    niriConfirm.hidden = true;
}

function sendNiriAction(action, param) {
    vibrate(15);
    socket.emit('niri_action', Object.assign({ action }, param !== undefined ? { param } : {}));
    socket.once('niri_result', (res) => {
        if (res && !res.ok) console.warn('[NIRI] error:', res.error);
    });
}

function renderNiriWorkspaces(list) {
    niriWorkspaces.innerHTML = '';
    list.forEach((w) => {
        const chip = document.createElement('button');
        chip.className = 'niri-chip' + (w.active ? ' active' : '');
        chip.textContent = w.name || w.idx;
        chip.addEventListener('click', () => sendNiriAction('focus-workspace', w.idx));
        niriWorkspaces.appendChild(chip);
    });
}

function loadNiriWorkspaces() {
    socket.emit('niri_workspaces', (resp) => {
        if (resp && resp.ok) renderNiriWorkspaces(resp.workspaces || []);
    });
}

btnNiri.addEventListener('click', openNiriPanel);
niriClose.addEventListener('click', closeNiriPanel);
niriOverlay.addEventListener('click', (e) => {
    if (e.target === niriOverlay) closeNiriPanel();
});
document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !niriOverlay.hidden) closeNiriPanel();
});

niriConfirmYes.addEventListener('click', () => {
    niriConfirm.hidden = true;
    sendNiriAction('quit');
});
niriConfirmNo.addEventListener('click', () => { niriConfirm.hidden = true; });

// Clics en los botones del panel (excluye el cuadro de confirmación)
document.querySelectorAll('#niri-overlay .niri-body .niri-action').forEach((btn) => {
    btn.addEventListener('click', () => {
        const action = btn.dataset.action;
        if (action === 'quit') {
            niriConfirm.hidden = false;
            return;
        }
        btn.classList.add('pressed');
        setTimeout(() => btn.classList.remove('pressed'), 150);
        sendNiriAction(action);
    });
});

// El servidor nos indica si niri está disponible para mostrar/ocultar el botón
socket.on('connect', () => {
    socket.emit('niri_status', (status) => {
        niriAvailable = !!(status && status.available);
        btnNiri.hidden = !niriAvailable;
    });
});

updateModeUI();
console.log('SAMPC UI cargada (rediseño Dark/Glass + panel niri)');