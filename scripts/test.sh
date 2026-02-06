#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[1/3] Building Swift app..."
swift build --package-path "$ROOT_DIR"

echo "[2/3] Checking Python worker syntax..."
"$ROOT_DIR/worker/.venv/bin/python" -m compileall -q "$ROOT_DIR/worker"

echo "[3/3] Running Python unit tests..."
"$ROOT_DIR/worker/.venv/bin/python" -m unittest discover -s "$ROOT_DIR/worker/tests" -p "test_*.py"

echo "All tests passed."
