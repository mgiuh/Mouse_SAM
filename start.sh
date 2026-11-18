#!/usr/bin/env bash
#
# SAMPC - Inicia el servidor de touchpad remoto.
#
# Se encarga de:
#   1. Crear/activar el entorno virtual e instalar dependencias Python.
#   2. Instalar ydotool si no está presente.
#   3. Preparar /dev/uinput (udev + grupo input).
#   4. Configurar ydotoold (servicio de usuario systemd o daemon root temporal).
#   5. Verificar que ydotool responda y arrancar el servidor.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/backend" || exit 1

USER_ID="$(id -u)"
USER_GID="$(id -g)"
USER_NAME="$(id -un)"
NEEDS_RELOGIN=false
DAEMON_MODE=""

SUDO=()
if [ "$USER_ID" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "❌ Se necesita 'sudo' para instalar ydotool y configurar /dev/uinput." >&2
        exit 1
    fi
    echo "🔐 Solicitando permisos de administrador..."
    if ! sudo -v; then
        echo "❌ No se pudieron obtener permisos de sudo." >&2
        exit 1
    fi
    SUDO=(sudo)
fi

say() { printf '%s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Entorno virtual de Python
# ---------------------------------------------------------------------------
setup_venv() {
    if [ ! -d "venv" ]; then
        say "📦 Creando entorno virtual..."
        python3 -m venv venv || die "No se pudo crear el entorno virtual (¿falta python3-venv?)"
    fi

    say "✅ Activando entorno virtual..."
    # shellcheck disable=SC1091
    source venv/bin/activate || die "No se pudo activar el entorno virtual"

    say "📚 Instalando dependencias..."
    if ! pip install -r requirements.txt -q --disable-pip-version-check; then
        die "Falló la instalación de dependencias (ver requirements.txt)"
    fi
}

# ---------------------------------------------------------------------------
# 2. Instalación de ydotool
# ---------------------------------------------------------------------------
install_ydotool() {
    if command -v ydotool >/dev/null 2>&1 && command -v ydotoold >/dev/null 2>&1; then
        say "✅ ydotool ya está instalado"
        return 0
    fi

    say "📦 Instalando ydotool..."

    if command -v pacman >/dev/null 2>&1; then
        "${SUDO[@]}" pacman -S --needed --noconfirm ydotool || return 1

    elif command -v dnf >/dev/null 2>&1; then
        "${SUDO[@]}" dnf install -y ydotool || return 1

    elif command -v apt-get >/dev/null 2>&1; then
        if apt-cache show ydotool >/dev/null 2>&1; then
            "${SUDO[@]}" apt-get install -y ydotool || return 1
        else
            warn "El paquete 'ydotool' no está en los repositorios de esta distro."
            warn "Compilalo desde fuente: https://github.com/ReimuNotMoe/ydotool"
            return 1
        fi

    elif command -v zypper >/dev/null 2>&1; then
        "${SUDO[@]}" zypper --non-interactive install ydotool || return 1

    else
        warn "No se reconoció el gestor de paquetes."
        warn "Instalá ydotool manualmente: https://github.com/ReimuNotMoe/ydotool"
        return 1
    fi

    if ! command -v ydotool >/dev/null 2>&1 || ! command -v ydotoold >/dev/null 2>&1; then
        warn "ydotool se instaló pero no se encontraron los binarios 'ydotool'/'ydotoold'."
        return 1
    fi

    say "✅ ydotool instalado"
}

# ---------------------------------------------------------------------------
# 3. Preparación de /dev/uinput y grupo input
# ---------------------------------------------------------------------------
setup_uinput() {
    say "🔧 Preparando /dev/uinput..."

    "${SUDO[@]}" modprobe uinput 2>/dev/null || true

    local rule_system="/usr/lib/udev/rules.d/80-uinput.rules"
    local rule_local="/etc/udev/rules.d/80-uinput.rules"

    if [ ! -f "$rule_system" ] && [ ! -f "$rule_local" ]; then
        say "   Instalando regla udev para uinput..."
        printf '%s\n' 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' \
            | "${SUDO[@]}" tee "$rule_local" >/dev/null || warn "No se pudo escribir $rule_local"
    fi

    if command -v udevadm >/dev/null 2>&1; then
        "${SUDO[@]}" udevadm control --reload-rules 2>/dev/null || true
        "${SUDO[@]}" udevadm trigger --name-match=uinput 2>/dev/null || true
    fi

    if [ ! -e /dev/uinput ]; then
        warn "/dev/uinput no existe. El módulo 'uinput' podría no estar disponible."
    fi

    # Permisos inmediatos para la sesión actual (persisten vía udev al reiniciar)
    if [ -e /dev/uinput ]; then
        local uinput_group uinput_mode
        uinput_group="$(stat -c '%G' /dev/uinput 2>/dev/null)"
        uinput_mode="$(stat -c '%a' /dev/uinput 2>/dev/null)"
        if [ "$uinput_group" != "input" ] || [ "$uinput_mode" != "660" ]; then
            "${SUDO[@]}" chgrp input /dev/uinput 2>/dev/null || true
            "${SUDO[@]}" chmod 0660 /dev/uinput 2>/dev/null || true
        fi
    fi
}

setup_input_group() {
    if [ "$USER_ID" -eq 0 ]; then
        return 0
    fi

    if ! getent group input >/dev/null 2>&1; then
        say "   Creando grupo 'input'..."
        "${SUDO[@]}" groupadd input || warn "No se pudo crear el grupo input"
    fi

    local members
    members="$(getent group input | cut -d: -f4 | tr ',' '\n')"
    if ! printf '%s\n' "$members" | grep -qx "$USER_NAME"; then
        say "   Agregando a '$USER_NAME' al grupo 'input'..."
        "${SUDO[@]}" usermod -aG input "$USER_NAME" || warn "No se pudo agregar al grupo input"
    fi

    # El grupo recién agregado no está activo hasta iniciar sesión de nuevo.
    if ! id -nG | tr ' ' '\n' | grep -qx input; then
        NEEDS_RELOGIN=true
    fi
}

# ---------------------------------------------------------------------------
# 4. Configuración del daemon ydotoold
# ---------------------------------------------------------------------------
user_socket_path() {
    printf '%s/.ydotool_socket' "${XDG_RUNTIME_DIR:-/run/user/$USER_ID}"
}

wait_for_ydotool() {
    local tries="${1:-15}"
    while [ "$tries" -gt 0 ]; do
        if ydotool mousemove -- 0 0 >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.3
        tries=$((tries - 1))
    done
    return 1
}

link_temp_socket() {
    local user_socket
    user_socket="$(user_socket_path)"
    if [ -d "$(dirname "$user_socket")" ]; then
        ln -sfn /tmp/.ydotool_socket "$user_socket" 2>/dev/null || true
    fi
}

start_root_fallback() {
    say "⚙️  Iniciando daemon ydotoold como root (modo temporal)..."

    "${SUDO[@]}" pkill -TERM -f 'ydotoold .*--socket-path=/tmp/.ydotool_socket' 2>/dev/null || true
    sleep 0.3
    "${SUDO[@]}" rm -f /tmp/.ydotool_socket 2>/dev/null || true

    "${SUDO[@]}" nohup ydotoold \
        --socket-path=/tmp/.ydotool_socket \
        --socket-own="${USER_ID}:${USER_GID}" \
        --socket-perm=0600 \
        >/tmp/ydotoold.log 2>&1 &

    link_temp_socket
    export YDOTOOL_SOCKET=/tmp/.ydotool_socket
    DAEMON_MODE="root-temporal"
}

start_user_service() {
    if ! systemctl --user show-environment >/dev/null 2>&1; then
        return 1
    fi

    say "🔧 Configurando servicio de usuario ydotoold..."
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable ydotool.service >/dev/null 2>&1 || true
    rm -f "$(user_socket_path)" 2>/dev/null || true
    unset YDOTOOL_SOCKET

    if ! systemctl --user restart ydotool.service; then
        warn "No se pudo iniciar ydotool.service"
        return 1
    fi

    DAEMON_MODE="usuario"
}

configure_daemon() {
    local group_active=false
    if [ "$USER_ID" -eq 0 ] || id -nG | tr ' ' '\n' | grep -qx input; then
        group_active=true
    fi

    if [ "$group_active" = true ]; then
        # Limpiar un daemon temporal de una ejecución anterior
        "${SUDO[@]}" pkill -TERM -f 'ydotoold .*--socket-path=/tmp/.ydotool_socket' 2>/dev/null || true

        if start_user_service && wait_for_ydotool 10; then
            say "✅ ydotoold activo como servicio de usuario"
            return 0
        fi
        warn "El servicio de usuario no respondió; usando daemon temporal."
    else
        # Dejar el servicio habilitado para que arranque tras el próximo login
        if systemctl --user show-environment >/dev/null 2>&1; then
            systemctl --user daemon-reload >/dev/null 2>&1 || true
            systemctl --user enable ydotool.service >/dev/null 2>&1 || true
        fi
        warn "Tu usuario aún no tiene el grupo 'input' activo en esta sesión."
    fi

    start_root_fallback

    if wait_for_ydotool 15; then
        say "✅ ydotoold activo como daemon temporal"
        return 0
    fi

    return 1
}

show_diagnostics() {
    echo
    echo "———— Diagnóstico ————"
    echo "Grupos del usuario: $(id -nG 2>/dev/null)"
    ls -l /dev/uinput 2>&1 || true
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user status --no-pager -l ydotool.service 2>&1 | tail -n 15 || true
    fi
    [ -f /tmp/ydotoold.log ] && { echo "--- /tmp/ydotoold.log ---"; tail -n 20 /tmp/ydotoold.log; }
    echo "———————————————————————"
}

cleanup() {
    # El daemon temporal solo debe vivir mientras corre el servidor.
    if [ "$DAEMON_MODE" = "root-temporal" ]; then
        "${SUDO[@]}" pkill -TERM -f 'ydotoold .*--socket-path=/tmp/.ydotool_socket' 2>/dev/null || true
        rm -f "$(user_socket_path)" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
say "🖱️  SAMPC - Iniciando servidor de touchpad remoto..."
say ""

setup_venv
install_ydotool || die "No se pudo instalar ydotool."
setup_uinput
setup_input_group

if ! configure_daemon; then
    show_diagnostics
    die "ydotoold no responde. Revisá el diagnóstico anterior."
fi

say ""
say "🌐 IPs disponibles:"
hostname -I 2>/dev/null || true

if [ "$NEEDS_RELOGIN" = true ]; then
    say ""
    warn "Agregamos tu usuario al grupo 'input'. Cerrá sesión y volvé a entrar"
    warn "para que ydotoold pueda ejecutarse como servicio permanente."
    warn "Por ahora se está usando un daemon temporal como root."
fi

say ""
say "🚀 Iniciando servidor..."
trap cleanup EXIT
python3 server.py
