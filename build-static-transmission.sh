#!/bin/bash

# Script to build statically linked transmission-daemon for macOS
# This creates a binary with no external library dependencies

set -e

echo "Building statically linked transmission-daemon..."

# Create a temporary build directory
BUILD_DIR="/tmp/transmission-static-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Download transmission source
echo "Downloading transmission source..."
curl -L https://github.com/transmission/transmission/releases/download/4.0.6/transmission-4.0.6.tar.xz -o transmission.tar.xz
tar -xf transmission.tar.xz
cd transmission-4.0.6

# Install build dependencies with Homebrew (if not already installed)
echo "Installing build dependencies..."
brew install cmake ninja pkg-config

# Install static versions of dependencies
echo "Installing static library dependencies..."
brew install --formula libevent openssl@3 curl zlib

# Create build directory
mkdir build
cd build

# Configure with static linking
echo "Configuring build with static linking..."
cmake .. \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_DAEMON=ON \
    -DENABLE_GTK=OFF \
    -DENABLE_QT=OFF \
    -DENABLE_MAC=OFF \
    -DENABLE_CLI=OFF \
    -DENABLE_UTILS=OFF \
    -DENABLE_TESTS=OFF \
    -DWITH_SYSTEMD=OFF \
    -DCMAKE_C_FLAGS="-static-libgcc" \
    -DCMAKE_CXX_FLAGS="-static-libstdc++" \
    -DCMAKE_EXE_LINKER_FLAGS="-static-libgcc -static-libstdc++" \
    -DOPENSSL_ROOT_DIR=$(brew --prefix openssl@3) \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DCURL_USE_STATIC_LIBS=TRUE

# Build
echo "Building transmission-daemon..."
ninja transmission-daemon

# Check the binary
echo "Checking dependencies..."
otool -L daemon/transmission-daemon

# Copy to project resources
DEST_DIR="/Users/stephengrigg/Documents/throttle2-15/Resources"
mkdir -p "$DEST_DIR"
cp daemon/transmission-daemon "$DEST_DIR/transmission-daemon-static"

echo "Static transmission-daemon built and copied to $DEST_DIR/transmission-daemon-static"
echo "Dependencies:"
otool -L "$DEST_DIR/transmission-daemon-static"

# Cleanup
cd /
rm -rf "$BUILD_DIR"

echo "Build complete!"
