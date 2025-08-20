#!/bin/bash

# Script to enable hardened runtime on transmission binaries
# This script signs the transmission-daemon and transmission-remote binaries
# with hardened runtime using your Developer ID Application certificate

set -e

RESOURCES_DIR="/Users/stephengrigg/Documents/throttle2-15/Resources"
SIGNING_IDENTITY="Developer ID Application: STEPHEN ROGER GRIGG (93C9M7982M)"

echo "Enabling hardened runtime for transmission binaries..."

# Check if binaries exist
if [ ! -f "$RESOURCES_DIR/transmission-daemon" ]; then
    echo "Error: transmission-daemon not found in $RESOURCES_DIR"
    exit 1
fi

if [ ! -f "$RESOURCES_DIR/transmission-remote" ]; then
    echo "Error: transmission-remote not found in $RESOURCES_DIR"
    exit 1
fi

# Sign transmission-daemon
echo "Signing transmission-daemon with hardened runtime..."
codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$RESOURCES_DIR/transmission-daemon"

# Sign transmission-remote
echo "Signing transmission-remote with hardened runtime..."
codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$RESOURCES_DIR/transmission-remote"

# Verify signatures
echo "Verifying signatures..."
echo "transmission-daemon:"
codesign --verify --verbose "$RESOURCES_DIR/transmission-daemon"
codesign -dv "$RESOURCES_DIR/transmission-daemon" | grep -E "(Authority|runtime)"

echo ""
echo "transmission-remote:"
codesign --verify --verbose "$RESOURCES_DIR/transmission-remote"
codesign -dv "$RESOURCES_DIR/transmission-remote" | grep -E "(Authority|runtime)"

echo ""
echo "Hardened runtime successfully enabled for both transmission binaries!"
