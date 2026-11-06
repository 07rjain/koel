#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/version.py check
python3 -m unittest discover -s scripts -p 'test_*.py'
scripts/test-swift.sh
cargo fmt --all -- --check
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
scripts/build-app.sh debug
