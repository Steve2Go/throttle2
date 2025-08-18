#!/bin/bash

# Script to bundle transmission-daemon with its required libraries
# This approach copies the dynamic libraries to the app bundle and updates paths

set -e

echo "Bundling transmission-daemon with required libraries..."

# Paths
RESOURCES_DIR="/Users/stephengrigg/Documents/throttle2-15/Resources"
LIBS_DIR="$RESOURCES_DIR/lib"

# Create lib directory
mkdir -p "$LIBS_DIR"

# Find the current transmission-daemon (assuming it's from homebrew)
TRANSMISSION_PATH=$(which transmission-daemon 2>/dev/null || echo "/opt/homebrew/bin/transmission-daemon")

if [ ! -f "$TRANSMISSION_PATH" ]; then
    echo "transmission-daemon not found. Installing via homebrew..."
    brew install transmission-cli
    TRANSMISSION_PATH="/opt/homebrew/bin/transmission-daemon"
fi

echo "Found transmission-daemon at: $TRANSMISSION_PATH"

# Copy transmission-daemon to resources
cp "$TRANSMISSION_PATH" "$RESOURCES_DIR/transmission-daemon"

# Make it executable
chmod +x "$RESOURCES_DIR/transmission-daemon"

# Function to copy a library and its dependencies
copy_lib() {
    local lib_path="$1"
    local lib_name=$(basename "$lib_path")
    
    # Skip if it's a system library
    if [[ "$lib_path" == /usr/lib/* ]] || [[ "$lib_path" == /System/* ]]; then
        return
    fi
    
    # Skip if already copied
    if [ -f "$LIBS_DIR/$lib_name" ]; then
        return
    fi
    
    echo "Copying library: $lib_name"
    cp "$lib_path" "$LIBS_DIR/"
    
    # Get dependencies of this library
    otool -L "$lib_path" | grep -E '\t(/opt/homebrew|/usr/local)' | awk '{print $1}' | while read dep; do
        if [ -f "$dep" ]; then
            copy_lib "$dep"
        fi
    done
}

# Get all non-system dependencies
echo "Finding dependencies..."
otool -L "$RESOURCES_DIR/transmission-daemon" | grep -E '\t(/opt/homebrew|/usr/local)' | awk '{print $1}' | while read lib; do
    copy_lib "$lib"
done

# Update library paths in transmission-daemon
echo "Updating library paths in transmission-daemon..."
otool -L "$RESOURCES_DIR/transmission-daemon" | grep -E '\t(/opt/homebrew|/usr/local)' | awk '{print $1}' | while read lib; do
    lib_name=$(basename "$lib")
    echo "Updating path for $lib_name"
    install_name_tool -change "$lib" "@executable_path/lib/$lib_name" "$RESOURCES_DIR/transmission-daemon"
done

# Update library paths in copied libraries
echo "Updating library paths in copied libraries..."
for lib_file in "$LIBS_DIR"/*; do
    if [ -f "$lib_file" ]; then
        echo "Processing $(basename "$lib_file")..."
        
        # Update the library's own ID
        lib_name=$(basename "$lib_file")
        install_name_tool -id "@executable_path/lib/$lib_name" "$lib_file"
        
        # Update dependencies in this library
        otool -L "$lib_file" | grep -E '\t(/opt/homebrew|/usr/local)' | awk '{print $1}' | while read dep; do
            dep_name=$(basename "$dep")
            if [ -f "$LIBS_DIR/$dep_name" ]; then
                echo "  Updating dependency: $dep_name"
                install_name_tool -change "$dep" "@executable_path/lib/$dep_name" "$lib_file"
            fi
        done
    fi
done

echo "Bundle complete!"
echo ""
echo "Files created:"
echo "  $RESOURCES_DIR/transmission-daemon"
echo "  $LIBS_DIR/ (containing $(ls "$LIBS_DIR" | wc -l | tr -d ' ') libraries)"
echo ""
echo "Dependencies for transmission-daemon:"
otool -L "$RESOURCES_DIR/transmission-daemon"
echo ""
echo "The bundled transmission-daemon should now work without external dependencies."
