#!/usr/bin/env bash
set -euo pipefail

echo "== Installing Linux desktop build dependencies =="
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  curl git unzip xz-utils zip \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libstdc++-12-dev \
  libasound2-dev \
  xdotool

echo "== Installing Flutter SDK =="
if [ ! -d /opt/flutter ]; then
  sudo git clone --depth 1 --branch stable https://github.com/flutter/flutter.git /opt/flutter
  sudo chown -R "$(id -u)":"$(id -g)" /opt/flutter
fi
export PATH="$PATH:/opt/flutter/bin"

flutter config --enable-linux-desktop --no-analytics
flutter precache --linux

echo "== Scaffolding native Linux platform folder =="
cd "$(dirname "$0")/.."
if [ ! -d linux ]; then
  flutter create --platforms=linux .
fi

echo "== Fetching packages =="
flutter pub get

echo "== Done =="
echo "Run the app with a real GEMINI_API_KEY:"
echo "  flutter run -d linux --dart-define=GEMINI_API_KEY=your_key_here"
echo "Open the noVNC desktop on the forwarded 6080 port to see and interact with it."
