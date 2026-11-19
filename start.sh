#!/usr/bin/env bash
#
# SAMPC - Inicia el servidor de touchpad remoto.
#
# Se encarga de:
#   1. Crear/activar el entorno virtual e instalar dependencias Python.
#   2. Instalar ydotool si no está presente.
#   3. Preparar /dev/uinput (udev + grupo input).
#   4. Configurar ydotoold (servicio de usuario systemd o daemon root temporal).
#   5. Verificar que ydotool responda.
#   6. Abrir el puerto del servidor en el firewall (ufw/firewalld) si hay uno activo.
#   7. Arrancar el servidor.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/backend" || exit 1

USER_ID="$(id -u)"
USER_GID="$(id -g)"
USER_NAME="$(id -un)"
NEEDS_RELOGIN=false
DAEMON_MODE=""

# sudo se solicita de forma diferida (ver ensure_sudo): solo la primera vez
# que un paso privilegiado realmente lo necesite, no al inicio.
SUDO=()

say() { printf '%s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

# Solicita sudo solo cuando un paso privilegiado lo requiere, y una sola vez.
SUDO_REQUESTED=false
ensure_sudo() {
    if [ "$USER_ID" -eq 0 ]; then
        return 0
    fi
    if [ "$SUDO_REQUESTED" = true ]; then
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        die "Se necesita 'sudo' para esta acción (instalar ydotool, configurar /dev/uinput o el firewall)."
    fi
    say "🔐 Solicitando permisos de administrador..."
    sudo -v || die "No se pudieron obtener permisos de sudo."
    SUDO_REQUESTED=true
    SUDO=(sudo)
}

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

    ensure_sudo
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
    local rule_system="/usr/lib/udev/rules.d/80-uinput.rules"
    local rule_local="/etc/udev/rules.d/80-uinput.rules"

    # ¿Ya está todo configurado? (regla udev + permisos de /dev/uinput)
    local already_ok=true
    if [ ! -f "$rule_system" ] && [ ! -f "$rule_local" ]; then
        already_ok=false
    fi
    if [ -e /dev/uinput ]; then
        local uinput_group uinput_mode
        uinput_group="$(stat -c '%G' /dev/uinput 2>/dev/null)"
        uinput_mode="$(stat -c '%a' /dev/uinput 2>/dev/null)"
        if [ "$uinput_group" != "input" ] || [ "$uinput_mode" != "660" ]; then
            already_ok=false
        fi
    fi

    if [ "$already_ok" = true ]; then
        say "✅ /dev/uinput y la regla udev ya están configurados"
        return 0
    fi

    ensure_sudo
    say "🔧 Preparando /dev/uinput..."

    "${SUDO[@]}" modprobe uinput 2>/dev/null || true

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

    # Si ya está activo en esta sesión, no hace falta tocar nada.
    if id -nG | tr ' ' '\n' | grep -qx input; then
        say "✅ Ya estás en el grupo 'input' en esta sesión"
        return 0
    fi

    ensure_sudo

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
    ensure_sudo
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
# 6. Firewall: abrir el puerto del servidor si hay ufw/firewalld activo
# ---------------------------------------------------------------------------
FIREWALL_PORT=1024

# ¿ufw activo? 'ufw status' sin root puede fallar en algunas distros
# (Arch); en ese caso se consulta el archivo de configuración.
ufw_active() {
    command -v ufw >/dev/null 2>&1 || return 1
    local first
    first="$(ufw status 2>/dev/null | head -n 1)"
    case "$first" in
        "Status: active")  return 0 ;;
        "Status: inactive") return 1 ;;
    esac
    grep -qx 'ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null
}

firewalld_active() {
    command -v firewall-cmd >/dev/null 2>&1 && \
        [ "$(firewall-cmd --state 2>/dev/null)" = "running" ]
}

# ¿Hay ya una regla ALLOW IN para el puerto? Con SUDO vacío (pre-menú) puede
# no listar nada si 'ufw status' exige root; tras ensure_sudo es fiable.
ufw_port_listed() {
    "${SUDO[@]}" ufw status 2>/dev/null | \
        grep -qE "^${FIREWALL_PORT}(/tcp)?([[:space:]]+on[[:space:]]+[^[:space:]]+)?[[:space:]]+ALLOW IN"
}

firewalld_port_listed() {
    firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | grep -qx "${FIREWALL_PORT}/tcp" && return 0
    firewall-cmd --list-rich-rules 2>/dev/null | grep -qE "port port=[\"']${FIREWALL_PORT}[\"']"
}

# Imprime una red/prefijo por línea por cada IPv4 privada (RFC 1918) de la PC,
# excluyendo loopback y direcciones no privadas.
lan_networks() {
    ip -o -f inet addr show 2>/dev/null | awk '
        {
            split($4, a, "/")
            ip_ = a[1]; pfx = a[2]
            if (ip_ == "" || pfx == "" || $2 == "lo") next
            split(ip_, o, ".")
            priv = (o[1] == 10) \
                || (o[1] == 192 && o[2] == 168) \
                || (o[1] == 172 && o[2] >= 16 && o[2] <= 31)
            if (!priv) next
            num = o[1] * 16777216 + o[2] * 65536 + o[3] * 256 + o[4]
            if (pfx > 0) { step = 2 ^ (32 - pfx); net = int(num / step) * step }
            else         { net = 0 }
            printf "%d.%d.%d.%d/%d\n",
                int(net / 16777216), int(net % 16777216 / 65536),
                int(net % 65536 / 256), net % 256, pfx
        }' | sort -u
}

open_ufw() {
    local mode="$1"; shift
    # Chequeo defensivo ya con privilegios, para no duplicar reglas.
    if ufw_port_listed; then
        say "✅ ufw: el puerto ${FIREWALL_PORT}/tcp ya estaba abierto"
        return 0
    fi
    local net
    if [ "$mode" = "any" ]; then
        say "   ufw: abriendo ${FIREWALL_PORT}/tcp a cualquier red..."
        "${SUDO[@]}" ufw allow "${FIREWALL_PORT}/tcp" \
            || warn "No se pudo abrir el puerto ${FIREWALL_PORT}/tcp con ufw"
        return 0
    fi
    for net in "$@"; do
        say "   ufw: permitiendo ${net} → ${FIREWALL_PORT}/tcp..."
        "${SUDO[@]}" ufw allow from "$net" to any port "$FIREWALL_PORT" proto tcp \
            || warn "No se pudo agregar la regla ufw para ${net}"
    done
}

open_firewalld() {
    local mode="$1"; shift
    local changed=false net rule

    if [ "$mode" = "any" ]; then
        say "   firewalld: abriendo ${FIREWALL_PORT}/tcp a cualquier red..."
        if "${SUDO[@]}" firewall-cmd --permanent --add-port="${FIREWALL_PORT}/tcp" 2>/dev/null; then
            changed=true
        else
            warn "No se pudo abrir el puerto ${FIREWALL_PORT}/tcp con firewalld"
        fi
    else
        for net in "$@"; do
            rule="rule family=\"ipv4\" source address=\"${net}\" port port=\"${FIREWALL_PORT}\" protocol=\"tcp\" accept"
            if "${SUDO[@]}" firewall-cmd --permanent --query-rich-rule="$rule" 2>/dev/null; then
                say "   firewalld: la regla para ${net} ya existía"
                continue
            fi
            say "   firewalld: permitiendo ${net} → ${FIREWALL_PORT}/tcp..."
            if "${SUDO[@]}" firewall-cmd --permanent --add-rich-rule="$rule" 2>/dev/null; then
                changed=true
            else
                warn "No se pudo agregar la regla de firewalld para ${net}"
            fi
        done
    fi

    if [ "$changed" = true ]; then
        if "${SUDO[@]}" firewall-cmd --reload >/dev/null 2>&1; then
            say "✅ firewalld: reglas aplicadas"
        else
            warn "Las reglas quedaron guardadas pero 'firewall-cmd --reload' falló."
        fi
    fi
}

setup_firewall() {
    local has_ufw=false has_firewalld=false fw_names=""
    if ufw_active; then has_ufw=true; fw_names="ufw"; fi
    if firewalld_active; then
        has_firewalld=true
        if [ -n "$fw_names" ]; then fw_names="$fw_names + firewalld"; else fw_names="firewalld"; fi
    fi

    if [ "$has_ufw" = false ] && [ "$has_firewalld" = false ]; then
        say "🔥 No se detectó ningún firewall activo; no hace falta abrir puertos"
        return 0
    fi

    local need_open=false
    if [ "$has_ufw" = true ] && ! ufw_port_listed; then need_open=true; fi
    if [ "$has_firewalld" = true ] && ! firewalld_port_listed; then need_open=true; fi
    if [ "$need_open" = false ]; then
        say "✅ ${fw_names}: el puerto ${FIREWALL_PORT}/tcp ya tiene reglas"
        return 0
    fi

    if [ ! -t 0 ]; then
        warn "${fw_names} está activo y el puerto ${FIREWALL_PORT}/tcp no está abierto."
        warn "Sin terminal interactiva no se modifican reglas; si el celular no conecta,"
        warn "ejecutá start.sh de nuevo y elegí una opción, o abrilo a mano."
        return 0
    fi

    say ""
    say "🔥 Firewall activo: ${fw_names}. El servidor escucha en el puerto ${FIREWALL_PORT}/tcp."
    say "   ¿Querés abrirlo para que pueda conectar el celular?"
    say "     1) Solo red local (recomendado) → solo tus subnets privados"
    say "     2) Cualquier red                → cualquier origen de la red puede conectar"
    say "     3) No abrir                     → omitir (el celular no conectará por red)"
    local choice="" mode
    read -r -p "   Opción [1]: " choice || choice=3
    case "${choice:-1}" in
        1) mode="lan" ;;
        2) mode="any" ;;
        *) say "   OK, no se modifica el firewall."; return 0 ;;
    esac

    local nets=()
    if [ "$mode" = "lan" ]; then
        mapfile -t nets < <(lan_networks)
        if [ "${#nets[@]}" -eq 0 ]; then
            warn "No se detectaron subnets privados (10.x / 172.16-31.x / 192.168.x)."
            warn "No se agregó ninguna regla. Si tu red no es privada, reejecutá"
            warn "start.sh y elegí 'Cualquier red'."
            return 0
        fi
        say "   Redes locales detectadas: ${nets[*]}"
    fi

    ensure_sudo
    if [ "$has_ufw" = true ]; then
        if [ "$mode" = "lan" ]; then open_ufw lan "${nets[@]}"; else open_ufw any; fi
    fi
    if [ "$has_firewalld" = true ]; then
        if [ "$mode" = "lan" ]; then open_firewalld lan "${nets[@]}"; else open_firewalld any; fi
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

setup_firewall

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
