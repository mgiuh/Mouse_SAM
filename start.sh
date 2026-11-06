#!/bin/bash

# Script para iniciar SAMPC en Linux

echo "🖱️  SAMPC - Iniciando servidor de touchpad remoto..."
echo ""

# Ir a la carpeta del backend
cd "$(dirname "$0")/backend" || exit

# Verificar si el entorno virtual existe
if [ ! -d "venv" ]; then
    echo "📦 Creando entorno virtual..."
    python3 -m venv venv
fi

# Activar entorno virtual
echo "✅ Activando entorno virtual..."
source venv/bin/activate

# Instalar/actualizar dependencias
echo "📚 Instalando dependencias..."
pip install -r requirements.txt -q

# Preparar socket y daemon de ydotool para Wayland
echo "🔧 Verificando daemon de ydotool..."
USER_ID=$(id -u)
USER_SOCKET="/run/user/${USER_ID}/.ydotool_socket"

# 1. Verificar si ydotoold está corriendo y si el socket es accesible
SOCKET_OK=false
if [ -S "$USER_SOCKET" ] && ydotool mousemove -- 0 0 >/dev/null 2>&1; then
    SOCKET_OK=true
elif [ -S "/tmp/.ydotool_socket" ] && YDOTOOL_SOCKET=/tmp/.ydotool_socket ydotool mousemove -- 0 0 >/dev/null 2>&1; then
    ln -sf /tmp/.ydotool_socket "$USER_SOCKET"
    SOCKET_OK=true
fi

# 2. Si no responde, iniciarlo con permisos 0666
if [ "$SOCKET_OK" = false ]; then
    echo "⚡ Iniciando ydotoold con permisos..."
    sudo pkill -9 ydotoold 2>/dev/null
    sudo rm -f /tmp/.ydotool_socket "$USER_SOCKET" 2>/dev/null
    sudo ydotoold --socket-perm=0666 &
    sleep 1
    ln -sf /tmp/.ydotool_socket "$USER_SOCKET"
fi

if ydotool mousemove -- 0 0 >/dev/null 2>&1; then
    echo "✅ ydotool listo y operativo"
else
    echo "⚠️ Advertencia: ydotool no respondió, revisa los permisos de sudo"
fi

# Obtener IP
echo ""
echo "🌐 IPs disponibles:"
hostname -I

echo ""
echo "🚀 Iniciando servidor..."
python3 server.py
