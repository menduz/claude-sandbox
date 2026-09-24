#!/usr/bin/env bash
set -euo pipefail

# Get the latest version from npm
echo "Checking latest version of @openai/codex..."
LATEST_VERSION=$(curl -s https://registry.npmjs.org/@openai/codex/latest | jq -r '.version')
echo "Latest version: $LATEST_VERSION"

# Get current version from codex.nix
CURRENT_VERSION=$(grep -oP 'version = "\K[^"]*' codex.nix)
echo "Current version: $CURRENT_VERSION"

if [ "$LATEST_VERSION" = "$CURRENT_VERSION" ]; then
    echo "Already up to date!"
    exit 0
fi

echo "New version available: $LATEST_VERSION"

# Download the GitHub release tarball and get its hash
TARBALL_URL="https://github.com/openai/codex/releases/download/rust-v${LATEST_VERSION}/codex-package-x86_64-unknown-linux-musl.tar.gz"
echo "Downloading $TARBALL_URL..."

NEW_HASH=$(nix-prefetch-url --type sha256 "$TARBALL_URL")
# Convert to SRI format to match the existing hash style in codex.nix
SRI_HASH=$(nix hash to-sri --type sha256 "$NEW_HASH")
echo "New hash: $SRI_HASH"

# Update codex.nix with new version and hash
echo "Updating codex.nix..."
sed -i "s|version = \".*\";|version = \"$LATEST_VERSION\";|" codex.nix
sed -i "s|latestHash = \".*\";|latestHash = \"$SRI_HASH\";|" codex.nix

echo "Updated codex.nix:"
echo "  Version: $CURRENT_VERSION -> $LATEST_VERSION"
echo "  Hash: $SRI_HASH"

echo ""
echo "You can now run 'nix build' to test the update."
