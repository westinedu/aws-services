#!/usr/bin/env python3
"""Interactive launcher for ticker_manager with preset parameters.

Run without arguments to use the interactive menu. Use --choice N for non-interactive mode.
"""
import os
import sys
import argparse
from typing import Optional

from ticker_manager import fetch_tickers, save_to_json, upload_to_s3

# Preset defaults (edit these values if you want different defaults)
DEFAULT_OUTPUT = "us_tickers.json"
DEFAULT_BUCKET = os.getenv("TICKER_S3_BUCKET", "my-default-bucket")
DEFAULT_OBJECT = "tickers/us_tickers.json"
DEFAULT_VERIFY_SSL = True


def run_generate(output: str, verify_ssl: bool) -> None:
    print(f"Generating tickers -> {output} (verify_ssl={verify_ssl})")
    tickers = fetch_tickers(verify_ssl=verify_ssl)
    save_to_json(tickers, output)


def run_upload(output: str, bucket: str, object_name: Optional[str]) -> None:
    print(f"Uploading {output} -> s3://{bucket}/{object_name or os.path.basename(output)}")
    upload_to_s3(output, bucket, object_name)


def interactive_menu() -> int:
    print("Ticker Manager Launcher")
    print("Presets:")
    print(f"  output: {DEFAULT_OUTPUT}")
    print(f"  bucket: {DEFAULT_BUCKET}")
    print(f"  object: {DEFAULT_OBJECT}")
    print("")
    print("Choose an action:")
    print("  1) Generate JSON only")
    print("  2) Upload JSON only (requires file to exist)")
    print("  3) Generate then Upload")
    print("  4) Exit")

    choice = input("Enter choice [1-4]: ").strip()
    if not choice:
        return 4
    try:
        return int(choice)
    except ValueError:
        return 4


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Launcher for ticker_manager with presets")
    parser.add_argument("--choice", type=int, help="Non-interactive choice: 1 gen,2 upload,3 gen+upload")
    parser.add_argument("--output", help="Output JSON file", default=DEFAULT_OUTPUT)
    parser.add_argument("--bucket", help="S3 bucket", default=DEFAULT_BUCKET)
    parser.add_argument("--object", help="S3 object name", default=DEFAULT_OBJECT)
    parser.add_argument("--insecure", help="Disable SSL verification", action="store_true")

    args = parser.parse_args(argv)

    verify_ssl = not args.insecure

    if args.choice is None:
        choice = interactive_menu()
    else:
        choice = args.choice

    if choice == 1:
        run_generate(args.output, verify_ssl)
        return 0
    if choice == 2:
        if not os.path.exists(args.output):
            print(f"Error: {args.output} not found. Generate it first or set --output.")
            return 2
        run_upload(args.output, args.bucket, args.object)
        return 0
    if choice == 3:
        run_generate(args.output, verify_ssl)
        run_upload(args.output, args.bucket, args.object)
        return 0

    print("Exit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
