#!/bin/bash
# setup.sh — Set up the ReticulumMessenger development environment.
set -e

echo "Setting up Reticulum Messenger..."

# Check for Xcode
if ! xcode-select -p &>/dev/null; then
    echo "Error: Xcode or Command Line Tools required."
    echo "Install with: xcode-select --install"
    exit 1
fi

# Check for XcodeGen
if ! command -v xcodegen &>/dev/null; then
    echo "Installing XcodeGen..."
    if command -v brew &>/dev/null; then
        brew install xcodegen
    else
        echo "Error: Homebrew required to install XcodeGen."
        echo "Install Homebrew: https://brew.sh"
        echo "Then run: brew install xcodegen"
        exit 1
    fi
fi

# Build the Swift package to validate
echo "Building ReticulumKit..."
cd "$(dirname "$0")/../Packages/ReticulumKit"
swift build
echo "ReticulumKit built successfully."

# Generate Xcode project
cd "$(dirname "$0")/.."
echo "Generating Xcode project..."
xcodegen generate
echo "Xcode project generated."

# Open in Xcode
echo "Opening in Xcode..."
open ReticulumMessenger.xcodeproj

echo ""
echo "Setup complete! The project is now open in Xcode."
echo "Select a simulator or device and press ⌘R to build and run."
