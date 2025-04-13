#!/bin/bash
# Cross-Platform FFmpeg Static Build Installer
# This script detects the platform and installs the appropriate FFmpeg static build

set -e

echo "************************************************"
echo "************************************************"
echo "**** FFMPEG STATIC INSTALLER"
echo "**** This script installs the latest static FFmpeg build appropriate for your platform"
echo "************************************************"
echo "************************************************"

# Check if FFmpeg is already installed
if command -v ffmpeg &>/dev/null && command -v ffprobe &>/dev/null; then
    FFMPEG_PATH=$(which ffmpeg)
    FFPROBE_PATH=$(which ffprobe)
    echo "FFmpeg is already installed:"
    echo "  ffmpeg: $FFMPEG_PATH ($(ffmpeg -version | head -n1))"
    echo "  ffprobe: $FFPROBE_PATH ($(ffprobe -version | head -n1))"
    
    # Check if --force flag is provided
    if [[ "$1" == "--force" ]]; then
        echo "Force flag detected. Proceeding with reinstallation..."
    else
        echo "Use --force to reinstall anyway."
        exit 0
    fi
fi

# Detect the operating system
OS="$(uname -s)"
ARCH="$(uname -m)"

echo "Detected operating system: $OS"
echo "Detected architecture: $ARCH"

# Create a temporary directory
TEMP_DIR=$(mktemp -d)
echo "Using temporary directory: $TEMP_DIR"

# Store the current directory
CURRENT_DIR=$(pwd)

# Check if sudo is available and required
if hash sudo 2>/dev/null; then
    echo "sudo is available. Will use it for system-wide installation."
    SUDO="sudo"
else
    echo "sudo is not available. Will attempt installation without it."
    SUDO=""
fi

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

# Cleanup on exit
cleanup() {
    echo "Cleaning up temporary directory..."
    rm -rf "$TEMP_DIR"
    cd "$CURRENT_DIR"
}
trap cleanup EXIT

# Function to install FFmpeg on macOS
install_macos() {
    echo "Installing FFmpeg for macOS ($ARCH)..."
    
    if [ "$ARCH" = "arm64" ]; then
        # M1/M2 Mac
        FFMPEG_URL="https://www.osxexperts.net/ffmpeg6arm.zip"
        FFPROBE_URL="https://www.osxexperts.net/ffprobe6arm.zip"
    else
        # Intel Mac
        # Get the URL from evermeet.cx
        if command_exists jq; then
            FFMPEG_URL=$(curl 'https://evermeet.cx/ffmpeg/info/ffmpeg/6.0' -fsS | jq -rc '.download.zip.url')
            FFPROBE_URL=$(curl 'https://evermeet.cx/ffmpeg/info/ffprobe/6.0' -fsS | jq -rc '.download.zip.url')
        else
            echo "jq is required for Intel Mac installation. Installing with Homebrew..."
            brew install jq
            FFMPEG_URL=$(curl 'https://evermeet.cx/ffmpeg/info/ffmpeg/6.0' -fsS | jq -rc '.download.zip.url')
            FFPROBE_URL=$(curl 'https://evermeet.cx/ffmpeg/info/ffprobe/6.0' -fsS | jq -rc '.download.zip.url')
        fi
    fi
    
    # Download files
    download_file "$FFMPEG_URL" "$TEMP_DIR/ffmpeg.zip"
    download_file "$FFPROBE_URL" "$TEMP_DIR/ffprobe.zip"
    
    # Extract
    unzip -o -d "$TEMP_DIR" "$TEMP_DIR/ffmpeg.zip"
    unzip -o -d "$TEMP_DIR" "$TEMP_DIR/ffprobe.zip"
    
    # Install to /usr/local/bin
    $SUDO mkdir -p /usr/local/bin
    $SUDO cp "$TEMP_DIR/ffmpeg" /usr/local/bin/
    $SUDO cp "$TEMP_DIR/ffprobe" /usr/local/bin/
    $SUDO chmod +x /usr/local/bin/ffmpeg
    $SUDO chmod +x /usr/local/bin/ffprobe
    
    echo "FFmpeg installed successfully for macOS!"
}

# Function to install FFmpeg on Linux
install_linux() {
    echo "Installing FFmpeg for Linux ($ARCH)..."
    
    # Map architecture to johnvansickle.com naming
    case "$ARCH" in
        x86_64)
            ARCH_NAME="amd64"
            ;;
        i686|i386)
            ARCH_NAME="i686"
            ;;
        armv6l|armv7l)
            ARCH_NAME="armhf"
            ;;
        aarch64)
            ARCH_NAME="arm64"
            ;;
        *)
            echo "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
    
    # URL for the latest release build
    FFMPEG_URL="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-${ARCH_NAME}-static.tar.xz"
    
    # Download the file
    download_file "$FFMPEG_URL" "$TEMP_DIR/ffmpeg.tar.xz"
    
    # Extract the archive
    cd "$TEMP_DIR"
    tar -xf "ffmpeg.tar.xz"
    
    # Find the extracted directory
    FFMPEG_DIR=$(find . -type d -name "ffmpeg-*-static" | head -n 1)
    
    if [ -z "$FFMPEG_DIR" ]; then
        echo "Error: Could not find extracted FFmpeg directory."
        exit 1
    fi
    
    # Install to /usr/local/bin
    $SUDO mkdir -p /usr/local/bin
    $SUDO cp "$FFMPEG_DIR/ffmpeg" /usr/local/bin/
    $SUDO cp "$FFMPEG_DIR/ffprobe" /usr/local/bin/
    $SUDO chmod +x /usr/local/bin/ffmpeg
    $SUDO chmod +x /usr/local/bin/ffprobe
    
    echo "FFmpeg installed successfully for Linux!"
}

# Function to install FFmpeg on FreeBSD
install_freebsd() {
    echo "Installing FFmpeg for FreeBSD ($ARCH)..."
    
    # Currently only supporting x64
    if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "x86_64" ]; then
        echo "Warning: FreeBSD installation only tested on x64 architecture."
    fi
    
    # URLs from Thefrank's repo
    FFMPEG_URL="https://github.com/Thefrank/ffmpeg-static-freebsd/releases/download/v6.0.0/ffmpeg"
    FFPROBE_URL="https://github.com/Thefrank/ffmpeg-static-freebsd/releases/download/v6.0.0/ffprobe"
    
    # Download the binaries
    download_file "$FFMPEG_URL" "$TEMP_DIR/ffmpeg"
    download_file "$FFPROBE_URL" "$TEMP_DIR/ffprobe"
    
    # Install to /usr/local/bin
    $SUDO mkdir -p /usr/local/bin
    $SUDO cp "$TEMP_DIR/ffmpeg" /usr/local/bin/
    $SUDO cp "$TEMP_DIR/ffprobe" /usr/local/bin/
    $SUDO chmod +x /usr/local/bin/ffmpeg
    $SUDO chmod +x /usr/local/bin/ffprobe
    
    echo "FFmpeg installed successfully for FreeBSD!"
}

# Function to install FFmpeg on Windows (WSL)
install_windows() {
    echo "Detected Windows environment through WSL..."
    
    # For WSL, we'll use the Linux installation method
    install_linux
}

# Print current ffmpeg version if it exists
print_current_version() {
    if command -v ffmpeg &>/dev/null; then
        echo "Current FFmpeg version:"
        ffmpeg -version | head -n 2
    fi
}

# Install based on the detected platform
print_current_version
case "$OS" in
    Darwin)
        install_macos
        ;;
    Linux)
        if grep -q Microsoft /proc/version 2>/dev/null; then
            # Windows Subsystem for Linux
            install_windows
        else
            # Regular Linux
            install_linux
        fi
        ;;
    FreeBSD)
        install_freebsd
        ;;
    *)
        echo "Unsupported operating system: $OS"
        exit 1
        ;;
esac

# Verify installation
if command_exists ffmpeg && command_exists ffprobe; then
    echo "************************************************"
    echo "** FFmpeg installation complete!"
    echo "** FFmpeg version: $(ffmpeg -version | head -n 1)"
    echo "** FFprobe version: $(ffprobe -version | head -n 1)"
    echo "************************************************"
else
    echo "Error: Installation verification failed. Please check the logs above."
    exit 1
fi

echo "FFmpeg static installation completed successfully!"
