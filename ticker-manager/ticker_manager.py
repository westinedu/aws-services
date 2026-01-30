#!/usr/bin/env python3
"""Fetch S&P500, Dow, Nasdaq-100 tickers, merge/dedupe, save JSON, optionally upload to S3.

Usage examples:
  # Generate JSON locally (with SSL verification)
  python3 ticker_manager.py --generate --output us_tickers.json

  # Generate JSON and upload to S3
  python3 ticker_manager.py --generate --output us_tickers.json --upload --bucket my-bucket --object path/us_tickers.json

  # If you're behind a proxy or having cert issues, disable SSL verification (not recommended):
  python3 ticker_manager.py --generate --output us_tickers.json --insecure
"""

import argparse
import json
import os
import sys
from io import StringIO
from typing import List, Set
import warnings

import pandas as pd
import requests

WIKI_URLS = {
    "sp500": "https://en.wikipedia.org/wiki/List_of_S%26P_500_companies",
    "dow": "https://en.wikipedia.org/wiki/Dow_Jones_Industrial_Average",
    "nasdaq100": "https://en.wikipedia.org/wiki/Nasdaq-100",
}


def read_tables_via_requests(url: str, verify: bool) -> List[pd.DataFrame]:
    if not verify:
        # Suppress noisy warning when user intentionally disables TLS verification.
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            try:
                import urllib3

                urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
            except Exception:
                pass

    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/121.0.0.0 Safari/537.36"
        )
    }
    r = requests.get(url, timeout=20, verify=verify, headers=headers)
    r.raise_for_status()
    # Pandas is deprecating passing raw HTML strings directly.
    return pd.read_html(StringIO(r.text))


def fetch_tickers(verify_ssl: bool = True) -> List[str]:
    symbols: Set[str] = set()

    # S&P 500
    try:
        tables = read_tables_via_requests(WIKI_URLS["sp500"], verify_ssl)
        sp = tables[0]
        if "Symbol" in sp.columns:
            symbols.update(sp["Symbol"].astype(str).tolist())
    except Exception as exc:  # pragma: no cover - network
        print("Warning: failed to fetch S&P 500:", exc)

    # Dow Jones
    try:
        tables = read_tables_via_requests(WIKI_URLS["dow"], verify_ssl)
        for tbl in tables:
            if "Symbol" in tbl.columns:
                symbols.update(tbl["Symbol"].astype(str).tolist())
                break
    except Exception as exc:  # pragma: no cover - network
        print("Warning: failed to fetch Dow Jones:", exc)

    # Nasdaq-100
    try:
        tables = read_tables_via_requests(WIKI_URLS["nasdaq100"], verify_ssl)
        for tbl in tables:
            # some pages use 'Ticker' as column name
            if "Ticker" in tbl.columns:
                symbols.update(tbl["Ticker"].astype(str).tolist())
                break
    except Exception as exc:  # pragma: no cover - network
        print("Warning: failed to fetch Nasdaq-100:", exc)

    # Clean + dedupe
    cleaned = []
    for s in symbols:
        if not isinstance(s, str):
            s = str(s)
        s = s.strip().upper()
        if not s:
            continue
        s = s.replace(".", "-")
        cleaned.append(s)

    unique = sorted(set(cleaned))
    return unique


def save_to_json(tickers: List[str], path: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(tickers, f, ensure_ascii=False, indent=2)
    print(f"Saved {len(tickers)} tickers to {path}")


def upload_to_s3(file_path: str, bucket: str, object_name: str = None) -> None:
    try:
        import boto3
    except ModuleNotFoundError as exc:
        raise ModuleNotFoundError(
            "boto3 is required for uploading. Install deps with: pip install -r AWS/ticker-manager/requirements.txt "
            "(or run the shell menu which auto-creates .venv)."
        ) from exc
    if object_name is None:
        object_name = os.path.basename(file_path)
    s3 = boto3.client("s3")
    try:
        s3.upload_file(file_path, bucket, object_name)
        print(f"Uploaded {file_path} to s3://{bucket}/{object_name}")
    except Exception as exc:
        print("S3 upload failed:", exc)
        raise


def main(argv: List[str] = None) -> int:
    parser = argparse.ArgumentParser(description="Fetch US tickers and optionally upload to S3")
    parser.add_argument("--generate", action="store_true", help="Generate the JSON file locally")
    parser.add_argument("--upload", action="store_true", help="Upload the JSON file to S3")
    parser.add_argument("--output", default="us_tickers.json", help="Output JSON file path")
    parser.add_argument("--bucket", help="S3 bucket name (required for --upload)")
    parser.add_argument("--object", help="S3 object name (optional)")
    parser.add_argument("--insecure", action="store_true", help="Disable SSL verification when fetching Wikipedia pages")

    args = parser.parse_args(argv)

    if not args.generate and not args.upload:
        parser.error("Specify at least one of --generate or --upload")

    if args.upload and not args.bucket:
        parser.error("--bucket is required when using --upload")

    if args.generate:
        tickers = fetch_tickers(verify_ssl=not args.insecure)
        save_to_json(tickers, args.output)

    if args.upload:
        if not os.path.exists(args.output):
            print(f"Error: output file {args.output} not found. Generate it first or specify the correct path.")
            return 2
        upload_to_s3(args.output, args.bucket, args.object)

    return 0


if __name__ == "__main__":
    sys.exit(main())
