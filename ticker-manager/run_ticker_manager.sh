#!/usr/bin/env bash
set -euo pipefail

# Wrapper to run ticker_manager.py without sourcing the virtualenv.
# It prefers .venv/bin/python when available, otherwise uses system python3.
# Usage:
#   ./run_ticker_manager.sh generate    # generate only
#   ./run_ticker_manager.sh upload      # upload only (requires generated file)
#   ./run_ticker_manager.sh both        # generate then upload

DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_PY="$DIR/.venv/bin/python"
if [ -x "$VENV_PY" ]; then
  PY="$VENV_PY"
else
  PY="$(command -v python3 || command -v python)"
fi

# Presets -- edit here if you want different defaults
OUTPUT="$DIR/us_tickers.json"
BUCKET="my-default-bucket"
OBJECT="tickers/us_tickers.json"
INSECURE_FLAG="--insecure" # default: disable cert verification to avoid local SSL issues

show_menu() {
  {
    echo "Ticker Manager Menu"
    echo "1) Generate JSON only"
    echo "2) Upload JSON only (requires file to exist)"
    echo "3) Generate then Upload"
    echo "4) Exit"
    printf "Choose [1-4]: "
  } > /dev/tty
  read -r choice < /dev/tty
  echo "$choice"
}

confirm_continue() {
  printf "Press ENTER to continue..." > /dev/tty
  read -r _ < /dev/tty
}

if [ "$#" -ge 1 ]; then
  CMD="$1"
else
  # Interactive menu
  CHOICE=$(show_menu)
  case "$CHOICE" in
    1) CMD="generate" ;;
    2) CMD="upload" ;;
    3) CMD="both" ;;
    *) echo "Exit."; exit 0 ;;
  esac
  confirm_continue
fi

case "$CMD" in
  generate)
    echo "Running generate -> $OUTPUT"
    "$PY" "$DIR/ticker_manager.py" --generate --output "$OUTPUT" $INSECURE_FLAG
    ;;
  upload)
    echo "Uploading $OUTPUT -> s3://$BUCKET/$OBJECT"
    "$PY" "$DIR/ticker_manager.py" --upload --output "$OUTPUT" --bucket "$BUCKET" --object "$OBJECT"
    ;;
  both)
    echo "Generating then uploading"
    "$PY" "$DIR/ticker_manager.py" --generate --output "$OUTPUT" $INSECURE_FLAG
    "$PY" "$DIR/ticker_manager.py" --upload --output "$OUTPUT" --bucket "$BUCKET" --object "$OBJECT"
    ;;
  *)
    echo "Usage: $0 {generate|upload|both}"
    exit 2
    ;;
esac
