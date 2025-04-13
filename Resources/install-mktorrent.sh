#
//  install-mktorrent.sh
//  Throttle 2
//
//  Created by Stephen Grigg on 12/4/2025.
//


#!/bin/bash
# mktorrent Installer for macOS and Linux without requiring Homebrew
# This script detects the platform and installs mktorrent appropriately

set -e

echo "************************************************"
echo "**** MKTORRENT INSTALLER"
echo "**** Simple torrent creation tool installer"
echo "************************************************"

# Check if mktorrent is already installed
if command -v mktorrent &>/dev/null; then
    MKTORRENT_PATH=$(which mktorrent)
    MKTORRENT_VERSION=$(mktorrent -h 2>&1 | head -n1)
    echo "mktorrent is already installed:"
    echo "  location: $MKTORRENT_PATH"
    echo "  version: $MKTORRENT_VERSION"
    
    if [[ "$1" == "--force" ]]; then
        echo "Force flag detected. Proceeding with reinstallation..."
    else
        echo "Use --force to reinstall anyway."
        exit 0  # Exit with success status
    fi
fi

# Detect the operating system and architecture
OS="$(uname -s)"
ARCH="$(uname -m)"

echo "Detected operating system: $OS"
echo "Detected architecture: $ARCH"

# Create a temporary directory
TEMP_DIR=$(mktemp -d)
echo "Using temporary directory: $TEMP_DIR"

# Store the current directory
CURRENT_DIR=$(pwd)

# Check if sudo is available
if hash sudo 2>/dev/null; then
    echo "sudo is available. Will use it for system-wide installation."
    SUDO="sudo"
    
    # Test if sudo requires password
    if ! sudo -n true 2>/dev/null; then
        echo "Sudo requires password."
        USE_SUDO_S=1
    else
        echo "Sudo does not require password for this user."
        USE_SUDO_S=0
    fi
else
    echo "sudo is not available. Will attempt installation without it."
    SUDO=""
    USE_SUDO_S=0
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

# Function to run sudo command with password if needed
run_sudo() {
    if [ "$USE_SUDO_S" -eq 1 ]; then
        # Use sudo -S to read password from stdin
        sudo -S "$@"
    else
        # Normal sudo without password
        sudo "$@"
    fi
}

# Function to install build dependencies
install_build_deps() {
    case "$OS" in
        Darwin)
            echo "macOS detected. No additional dependencies needed for basic build."
            ;;
        Linux)
            echo "Installing build dependencies for Linux..."
            if command_exists apt-get; then
                run_sudo apt-get update
                run_sudo apt-get install -y build-essential libssl-dev
            elif command_exists dnf; then
                run_sudo dnf install -y gcc make openssl-devel
            elif command_exists yum; then
                run_sudo yum install -y gcc make openssl-devel
            elif command_exists pacman; then
                run_sudo pacman -Sy --noconfirm base-devel openssl
            elif command_exists zypper; then
                run_sudo zypper install -y gcc make libopenssl-devel
            elif command_exists apk; then
                run_sudo apk add build-base openssl-dev
            else
                echo "Warning: Couldn't identify package manager to install dependencies."
                echo "Build might fail if gcc, make and OpenSSL dev libraries are missing."
            fi
            ;;
    esac
}

# Function to build and install mktorrent from source
install_from_source() {
    echo "Installing mktorrent from source..."
    
    # Install build dependencies
    install_build_deps
    
    # Download source code
    cd "$TEMP_DIR"
    echo "Downloading mktorrent source code..."
    download_file "https://github.com/pobrn/mktorrent/archive/v1.1.tar.gz" "$TEMP_DIR/mktorrent.tar.gz"
    
    # Extract
    tar -xzf mktorrent.tar.gz
    cd mktorrent-*
    
    # Build
    echo "Building mktorrent..."
    make PREFIX=/usr/local
    
    # Install
    echo "Installing mktorrent..."
    run_sudo make PREFIX=/usr/local install
}

# Function to install with package manager (Linux)
install_with_package_manager() {
    echo "Installing mktorrent with package manager..."
    
    if command_exists apt-get; then
        echo "Detected apt-based system (Debian/Ubuntu)..."
        run_sudo apt-get update
        run_sudo apt-get install -y mktorrent
    elif command_exists dnf; then
        echo "Detected dnf-based system (Fedora/RHEL)..."
        run_sudo dnf install -y mktorrent
    elif command_exists yum; then
        echo "Detected yum-based system (CentOS/older RHEL)..."
        run_sudo yum install -y mktorrent
    elif command_exists pacman; then
        echo "Detected pacman-based system (Arch)..."
        run_sudo pacman -Sy --noconfirm mktorrent
    elif command_exists zypper; then
        echo "Detected zypper-based system (openSUSE)..."
        run_sudo zypper install -y mktorrent
    elif command_exists apk; then
        echo "Detected apk-based system (Alpine)..."
        run_sudo apk add mktorrent
    else
        echo "Package manager not detected or mktorrent not available in repos."
        echo "Falling back to source installation."
        install_from_source
    fi
}

# Choose installation method based on platform
case "$OS" in
    Darwin)
        # On macOS, we'll compile from source
        install_from_source
        ;;
    Linux)
        # On Linux, try package manager first, then fall back to source
        if command_exists apt-get || command_exists dnf || command_exists yum || command_exists pacman || command_exists zypper || command_exists apk; then
            install_with_package_manager
        else
            install_from_source
        fi
        ;;
    *)
        echo "Unsupported operating system: $OS"
        echo "Attempting source installation as a fallback..."
        install_from_source
        ;;
esac

# Verify installation
if command_exists mktorrent; then
    echo "************************************************"
    echo "** mktorrent installation complete!"
    echo "** Location: $(which mktorrent)"
    echo "** Version info:"
    mktorrent -h 2>&1 | head -n 2
    echo "************************************************"
    echo "Successfully installed mktorrent!"
    echo ""
    echo "Usage examples:"
    echo "  mktorrent -a http://tracker.example.com:6969/announce -o output.torrent input_file_or_directory"
    echo "  mktorrent -p -a http://tracker.example.com:6969/announce -o private.torrent input_directory"
    echo "  mktorrent -v -l 24 -a http://tracker.example.com:6969/announce -o large_file.torrent large_file"
else
    echo "Error: Installation verification failed. mktorrent may not be in PATH."
    exit 1
fi
