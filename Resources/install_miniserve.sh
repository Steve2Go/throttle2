#
//  install_miniserve.sh
//  Throttle 2
//
//  Created by Stephen Grigg on 16/4/2025.
//


#!/bin/bash
# Miniserve Static Binary Installer for Throttle 2
# This script downloads and sets up miniserve in a temporary location

set -e

echo "************************************************"
echo "************************************************"
echo "**** MINISERVE STREAMING SERVER SETUP"
echo "**** This script sets up miniserve for file streaming"
echo "************************************************"
echo "************************************************"

# Create a dedicated temporary directory for Throttle 2 streaming
THROTTLE_TEMP_DIR="/tmp/throttle-streaming"
mkdir -p "$THROTTLE_TEMP_DIR"
echo "Using directory: $THROTTLE_TEMP_DIR"

# Detect the operating system and architecture
OS="$(uname -s)"
ARCH="$(uname -m)"

echo "Detected operating system: $OS"
echo "Detected architecture: $ARCH"

# Map architecture to miniserve naming conventions
case "$ARCH" in
    x86_64)
        ARCH_NAME="x86_64"
        ;;
    amd64)
        ARCH_NAME="x86_64"
        ;;
    aarch64)
        ARCH_NAME="aarch64"
        ;;
    arm64)
        ARCH_NAME="aarch64"
        ;;
    armv7*)
        ARCH_NAME="armv7"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

# Map OS to miniserve naming conventions
case "$OS" in
    Linux)
        OS_NAME="unknown-linux-musl"
        ;;
    Darwin)
        OS_NAME="apple-darwin"
        ;;
    FreeBSD)
        OS_NAME="unknown-freebsd"
        ;;
    *)
        echo "Unsupported operating system: $OS"
        exit 1
        ;;
esac

# Set miniserve version and URL
MINISERVE_VERSION="0.24.0"
MINISERVE_BINARY="miniserve-${MINISERVE_VERSION}-${ARCH_NAME}-${OS_NAME}"
MINISERVE_URL="https://github.com/svenstaro/miniserve/releases/download/v${MINISERVE_VERSION}/${MINISERVE_BINARY}"

# Download miniserve if it doesn't exist or version is different
MINISERVE_PATH="${THROTTLE_TEMP_DIR}/miniserve"
MINISERVE_VERSION_FILE="${THROTTLE_TEMP_DIR}/version.txt"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to download a file
download_file() {
    local url="$1"
    local output="$2"
    
    echo "Downloading $url to $output"
    
    if command_exists curl; then
        curl -L -o "$output" "$url"
    elif command_exists wget; then
        wget -O "$output" "$url"
    else
        echo "Error: Neither curl nor wget is available. Please install one of them."
        exit 1
    fi
}

# Check if we need to download miniserve
if [ -f "$MINISERVE_VERSION_FILE" ] && [ -f "$MINISERVE_PATH" ]; then
    CURRENT_VERSION=$(cat "$MINISERVE_VERSION_FILE")
    if [ "$CURRENT_VERSION" = "$MINISERVE_VERSION" ]; then
        echo "Miniserve version $MINISERVE_VERSION is already installed."
    else
        echo "Updating miniserve from version $CURRENT_VERSION to $MINISERVE_VERSION"
        download_file "$MINISERVE_URL" "$MINISERVE_PATH"
        echo "$MINISERVE_VERSION" > "$MINISERVE_VERSION_FILE"
    fi
else
    echo "Installing miniserve version $MINISERVE_VERSION"
    download_file "$MINISERVE_URL" "$MINISERVE_PATH"
    echo "$MINISERVE_VERSION" > "$MINISERVE_VERSION_FILE"
fi

# Make miniserve executable
chmod +x "$MINISERVE_PATH"

# Test miniserve version
INSTALLED_VERSION=$("$MINISERVE_PATH" --version | head -n1 | cut -d' ' -f2)
echo "Installed miniserve version: $INSTALLED_VERSION"

# Create a basic configuration/wrapper script
cat > "${THROTTLE_TEMP_DIR}/start-streaming.sh" << 'EOL'
#!/bin/bash
# Wrapper script to start miniserve with appropriate options

# Get parameters
PORT="$1"
DIR_TO_SERVE="$2"
LOGFILE="${3:-/tmp/throttle-streaming/miniserve.log}"

# Ensure the directory exists
if [ ! -d "$DIR_TO_SERVE" ]; then
    echo "Error: Directory to serve does not exist: $DIR_TO_SERVE" >&2
    exit 1
fi

# Kill any existing miniserve instance on the same port
pkill -f "miniserve.*--port $PORT" || true

# Start miniserve with options
/tmp/throttle-streaming/miniserve \
  --port "$PORT" \
  --verbose \
  --media-type \
  --enable-cors \
  --index \
  "$DIR_TO_SERVE" > "$LOGFILE" 2>&1 &

# Save the PID to a file
echo $! > "/tmp/throttle-streaming/miniserve-${PORT}.pid"

# Wait a second to ensure it started
sleep 1

# Check if miniserve is running
if kill -0 $! 2>/dev/null; then
    echo "Miniserve started successfully on port $PORT, serving $DIR_TO_SERVE"
    echo "SUCCESS:$PORT:$!" # Success marker with port and PID
    exit 0
else
    echo "Failed to start miniserve"
    exit 1
fi
EOL

# Make the wrapper script executable
chmod +x "${THROTTLE_TEMP_DIR}/start-streaming.sh"

# Create a stop script
cat > "${THROTTLE_TEMP_DIR}/stop-streaming.sh" << 'EOL'
#!/bin/bash
# Script to stop miniserve instance

# Get parameters
PORT="$1"
PID_FILE="/tmp/throttle-streaming/miniserve-${PORT}.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "Stopping miniserve on port $PORT (PID: $PID)"
        kill "$PID"
        rm "$PID_FILE"
        echo "Stopped miniserve successfully"
    else
        echo "Miniserve process is not running (PID: $PID)"
        rm "$PID_FILE"
    fi
else
    # Try to find and kill by port
    echo "PID file not found, trying to find process by port"
    pkill -f "miniserve.*--port $PORT" || true
fi
EOL

# Make the stop script executable
chmod +x "${THROTTLE_TEMP_DIR}/stop-streaming.sh"

echo "************************************************"
echo "*** Miniserve setup completed successfully!"
echo "*** Version: $INSTALLED_VERSION"
echo "*** Binary location: $MINISERVE_PATH"
echo "*** Start script: ${THROTTLE_TEMP_DIR}/start-streaming.sh"
echo "*** Stop script: ${THROTTLE_TEMP_DIR}/stop-streaming.sh"
echo "************************************************"
echo "SUCCESS"