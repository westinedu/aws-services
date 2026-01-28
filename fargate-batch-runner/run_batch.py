import json
import os
import time
from typing import List

import boto3
import requests


DEFAULT_SYMBOLS = [
    "AAPL",
    "MSFT",
    "GOOGL",
    "AMZN",
    "META",
    "NVDA",
    "AMD",
    "TSLA",
    "AVGO",
    "NFLX",
]


def _env_bool(key: str, default: bool) -> bool:
    val = os.getenv(key)
    if val is None:
        return default
    return val.strip().lower() in {"1", "true", "yes", "y"}


def _env_int(key: str, default: int) -> int:
    val = os.getenv(key)
    if val is None:
        return default
    try:
        return int(val)
    except ValueError:
        return default


def _parse_symbols(raw: str) -> List[str]:
    if not raw:
        return DEFAULT_SYMBOLS
    return [s.strip().upper() for s in raw.split(",") if s.strip()]


def _load_symbols_from_s3(uri: str) -> List[str]:
    if not uri.startswith("s3://"):
        return []
    _, _, rest = uri.partition("s3://")
    bucket, _, key = rest.partition("/")
    if not bucket or not key:
        return []

    obj = boto3.client("s3").get_object(Bucket=bucket, Key=key)
    raw = obj["Body"].read().decode("utf-8")

    try:
        data = json.loads(raw)
        if isinstance(data, list):
            return [str(s).strip().upper() for s in data if str(s).strip()]
        if isinstance(data, dict):
            symbols = data.get("symbols") or data.get("tickers") or []
            return [str(s).strip().upper() for s in symbols if str(s).strip()]
    except json.JSONDecodeError:
        pass

    return [s.strip().upper() for s in raw.splitlines() if s.strip()]


def main() -> None:
    base_url = os.getenv("TRADING_BASE_URL", "").strip().rstrip("/")
    if not base_url:
        raise SystemExit("TRADING_BASE_URL is required")

    s3_uri = os.getenv("TRADING_TICKERS_S3_URI", "").strip()
    if s3_uri:
        symbols = _load_symbols_from_s3(s3_uri)
    else:
        symbols = _parse_symbols(os.getenv("TRADING_SYMBOLS", ""))
    years = _env_int("TRADING_YEARS", 3)
    incremental = _env_bool("TRADING_INCREMENTAL", True)
    fill_year = _env_bool("TRADING_FILL_YEAR", False)
    year = os.getenv("TRADING_YEAR")
    end = os.getenv("TRADING_END")

    batch_size = _env_int("BATCH_SIZE", 1)
    sleep_seconds = _env_int("SLEEP_SECONDS", 1)
    timeout_seconds = _env_int("HTTP_TIMEOUT", 120)

    url = f"{base_url}/api/v1/stocks/refresh"

    print(
        json.dumps(
            {
                "base_url": base_url,
                "symbols": symbols,
                "years": years,
                "incremental": incremental,
                "fillYear": fill_year,
                "year": year,
                "end": end,
                "batch_size": batch_size,
            },
            ensure_ascii=False,
        )
    )

    for i in range(0, len(symbols), batch_size):
        batch = symbols[i : i + batch_size]
        payload = {
            "symbols": batch,
            "years": years,
            "incremental": incremental,
            "fillYear": fill_year,
        }
        if year:
            payload["year"] = int(year)
        if end:
            payload["end"] = end

        print(f"Calling refresh for {batch}")
        try:
            resp = requests.post(url, json=payload, timeout=timeout_seconds)
            print(resp.status_code, resp.text)
        except Exception as exc:
            print(f"Request failed for {batch}: {exc}")

        if sleep_seconds > 0:
            time.sleep(sleep_seconds)


if __name__ == "__main__":
    main()
