#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh "${1:-debug}"
scripts/install.sh
open "$HOME/Applications/Local Whisper.app"
