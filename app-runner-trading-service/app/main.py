from __future__ import annotations

import json
import os
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

import boto3
import pandas as pd
import requests
from pandas_datareader import data as pdr
import yfinance as yf
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

app = FastAPI(title="Trading Market Data Service", version="1.0.0")


_YF_SESSION: Optional[requests.Session] = None


def _yf_session() -> requests.Session:
    global _YF_SESSION
    if _YF_SESSION is None:
        session = requests.Session()
        session.headers.update(
            {
                "User-Agent": (
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/122.0.0.0 Safari/537.36"
                ),
                "Accept": "text/html,application/json;q=0.9,*/*;q=0.8",
                "Accept-Language": "en-US,en;q=0.9",
            }
        )
        _YF_SESSION = session
    return _YF_SESSION


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _s3_bucket() -> str:
    return (
        os.getenv("TRADING_S3_BUCKET")
        or os.getenv("MARKETDATA_S3_BUCKET")
        or os.getenv("S3_BUCKET")
        or ""
    ).strip()


def _s3_prefix() -> str:
    return (os.getenv("TRADING_S3_PREFIX") or "US-stocks").strip().strip("/")


def _is_s3_enabled() -> bool:
    if (os.getenv("TRADING_DISABLE_S3") or "").lower() in {"1", "true", "yes"}:
        return False
    return bool(_s3_bucket())


def _s3_client():
    return boto3.client("s3")


def _year_key(symbol: str, year: int) -> str:
    prefix = _s3_prefix()
    safe_symbol = symbol.upper().replace("/", "-")
    return f"{prefix}/yearly/symbol={safe_symbol}/{safe_symbol}_{year}.json"


def _manifest_key(symbol: str) -> str:
    prefix = _s3_prefix()
    safe_symbol = symbol.upper().replace("/", "-")
    return f"{prefix}/yearly/symbol={safe_symbol}/manifest.json"


def _parse_date(s: str) -> datetime:
    return datetime.fromisoformat(s)


def _merge_records(existing: List[Dict[str, Any]], incoming: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    by_date: Dict[str, Dict[str, Any]] = {r["date"]: r for r in existing if "date" in r}
    for r in incoming:
        if "date" in r:
            by_date[r["date"]] = r
    merged = list(by_date.values())
    merged.sort(key=lambda r: r.get("date", ""))
    return merged


def _split_by_year(records: List[Dict[str, Any]]) -> Dict[int, List[Dict[str, Any]]]:
    out: Dict[int, List[Dict[str, Any]]] = {}
    for r in records:
        if "date" not in r:
            continue
        y = _parse_date(r["date"]).year
        out.setdefault(y, []).append(r)
    for y in out:
        out[y].sort(key=lambda r: r.get("date", ""))
    return out


def _df_to_records(df: pd.DataFrame, symbol: str) -> List[Dict[str, Any]]:
    df = df.copy()
    df = df.reset_index()
    df.rename(
        columns={
            "Date": "date",
            "Open": "open",
            "High": "high",
            "Low": "low",
            "Close": "close",
            "Adj Close": "adj_close",
            "Volume": "volume",
        },
        inplace=True,
    )
    df["symbol"] = symbol.upper()
    df["date"] = df["date"].dt.strftime("%Y-%m-%d")
    records = df.to_dict(orient="records")
    return records


def _fetch_daily(symbol: str, start_dt: datetime, end_dt: datetime) -> List[Dict[str, Any]]:
    start = start_dt.date().isoformat()
    end = (end_dt + timedelta(days=1)).date().isoformat()
    session = _yf_session()
    try:
        ticker = yf.Ticker(symbol, session=session)
        df = ticker.history(
            start=start,
            end=end,
            interval="1d",
            auto_adjust=False,
        )
    except Exception:
        df = None

    if df is not None and not df.empty:
        if isinstance(df.index, pd.DatetimeIndex) and df.index.tz is not None:
            df.index = df.index.tz_convert("UTC").tz_localize(None)
    else:
        try:
            stooq_symbol = symbol if "." in symbol else f"{symbol}.US"
            df = pdr.DataReader(stooq_symbol, "stooq", start, end)
            df = df.sort_index()
        except Exception:
            return []
    return _df_to_records(df, symbol)


def _put_s3_json(key: str, payload: Dict[str, Any]) -> None:
    if not _is_s3_enabled():
        return
    bucket = _s3_bucket()
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    _s3_client().put_object(Bucket=bucket, Key=key, Body=body, ContentType="application/json")


def _get_s3_json(key: str) -> Optional[Dict[str, Any]]:
    if not _is_s3_enabled():
        return None
    bucket = _s3_bucket()
    try:
        resp = _s3_client().get_object(Bucket=bucket, Key=key)
        data = resp["Body"].read()
        return json.loads(data)
    except Exception:
        return None


def _update_manifest(symbol: str, year: int, payload: Dict[str, Any]) -> None:
    if not _is_s3_enabled():
        return
    key = _manifest_key(symbol)
    manifest = _get_s3_json(key) or {}
    years = set(manifest.get("years") or [])
    years.add(year)

    latest_by_year = manifest.get("latestDateByYear") or {}
    data = payload.get("data") or []
    if data:
        latest_by_year[str(year)] = data[-1].get("date")

    # Compute latest date across years (YYYY-MM-DD string comparison works)
    latest_date = None
    for v in latest_by_year.values():
        if v and (latest_date is None or v > latest_date):
            latest_date = v

    new_manifest = {
        "symbol": symbol,
        "updatedAt": _utc_now().isoformat(),
        "years": sorted(years),
        "latestDateByYear": latest_by_year,
        "latestDate": latest_date,
    }
    _put_s3_json(key, new_manifest)


class RefreshRequest(BaseModel):
    symbols: List[str] = Field(default_factory=list, description="Ticker list")
    years: int = Field(default=3, ge=1, le=20)
    start: Optional[str] = Field(default=None, description="YYYY-MM-DD")
    end: Optional[str] = Field(default=None, description="YYYY-MM-DD")
    store: bool = Field(default=True, description="Write to S3")
    incremental: bool = Field(default=True, description="If true, only fetch recent changes")
    fillYear: bool = Field(default=False, description="If true, backfill current year in one batch")
    year: Optional[int] = Field(default=None, description="Target year for backfill")


@app.get("/")
def root():
    return {"service": "trading", "docs": "/docs", "openapi": "/openapi.json"}


@app.get("/health")
def health():
    return {"ok": True, "service": "trading", "ts": _utc_now().isoformat()}


@app.get("/api/v1/stocks/daily")
def get_daily(
    symbol: str,
    years: int = 3,
    start: Optional[str] = None,
    end: Optional[str] = None,
    incremental: bool = True,
    lookbackDays: int = 10,
    fillYear: bool = False,
    year: Optional[int] = None,
):
    symbol = symbol.strip().upper()
    if not symbol:
        raise HTTPException(status_code=400, detail="symbol is required")

    now = _utc_now()
    end_date = datetime.fromisoformat(end) if end else now
    target_year = year or end_date.year

    # Backfill the whole target year if requested (e.g., missing months).
    if fillYear:
        start_dt = datetime(target_year, 1, 1, tzinfo=timezone.utc)
        end_dt = end_date
        records = _fetch_daily(symbol, start_dt, end_dt)
        by_year = _split_by_year(records)
        for y, rows in by_year.items():
            key = _year_key(symbol, y)
            cached = _get_s3_json(key) or {}
            merged = _merge_records(cached.get("data") or [], rows)
            payload = {
                "symbol": symbol,
                "year": y,
                "fetchedAt": _utc_now().isoformat(),
                "count": len(merged),
                "data": merged,
            }
            _put_s3_json(key, payload)
            _update_manifest(symbol, y, payload)

    # Incremental update current year by default
    if incremental and not start and not end:
        key = _year_key(symbol, target_year)
        cached = _get_s3_json(key) or {}
        cached_data = cached.get("data") or []
        if cached_data:
            last_date = _parse_date(cached_data[-1]["date"]).date().isoformat()
            start = (datetime.fromisoformat(last_date) - timedelta(days=lookbackDays)).date().isoformat()
        start_dt = datetime.fromisoformat(start) if start else datetime(target_year, 1, 1, tzinfo=timezone.utc)
        end_dt = end_date
        records = _fetch_daily(symbol, start_dt, end_dt)
        merged = _merge_records(cached_data, records)
        payload = {
            "symbol": symbol,
            "year": target_year,
            "fetchedAt": _utc_now().isoformat(),
            "count": len(merged),
            "data": merged,
        }
        _put_s3_json(key, payload)
        _update_manifest(symbol, target_year, payload)

    # Assemble response from year-partitioned files (no trimming/deletion)
    years_list = [end_date.year - i for i in range(years)]
    all_rows: List[Dict[str, Any]] = []
    for y in sorted(set(years_list)):
        cached = _get_s3_json(_year_key(symbol, y))
        if cached and cached.get("data"):
            all_rows.extend(cached.get("data"))

    all_rows.sort(key=lambda r: r.get("date", ""))

    payload = {
        "symbol": symbol,
        "years": years,
        "start": start,
        "end": end,
        "fetchedAt": _utc_now().isoformat(),
        "count": len(all_rows),
        "data": all_rows,
    }
    return {**payload, "source": "s3" if _is_s3_enabled() else "upstream"}


@app.post("/api/v1/stocks/refresh")
def refresh(req: RefreshRequest):
    if not req.symbols:
        raise HTTPException(status_code=400, detail="symbols is required")

    results = []
    for raw_symbol in req.symbols:
        symbol = raw_symbol.strip().upper()
        if not symbol:
            continue
        now = _utc_now()
        end_dt = datetime.fromisoformat(req.end) if req.end else now
        target_year = req.year or end_dt.year

        # Optional full-year backfill (for missing months)
        if req.fillYear:
            start_dt = datetime(target_year, 1, 1, tzinfo=timezone.utc)
            records = _fetch_daily(symbol, start_dt, end_dt)
            by_year = _split_by_year(records)
            for y, rows in by_year.items():
                key = _year_key(symbol, y)
                cached = _get_s3_json(key) or {}
                merged = _merge_records(cached.get("data") or [], rows)
                payload = {
                    "symbol": symbol,
                    "year": y,
                    "fetchedAt": _utc_now().isoformat(),
                    "count": len(merged),
                    "data": merged,
                }
                if req.store:
                    _put_s3_json(key, payload)
                    _update_manifest(symbol, y, payload)

        # Incremental update current year
        start = req.start
        end = req.end
        key = _year_key(symbol, target_year)
        cached = _get_s3_json(key) if req.incremental else None
        cached_data = cached.get("data") if cached else []
        if req.incremental and not start and not end and cached_data:
            last_date = cached_data[-1]["date"]
            start = (_parse_date(last_date) - timedelta(days=10)).date().isoformat()

        if req.incremental and not start and not end and not cached_data:
            start = datetime(target_year, 1, 1, tzinfo=timezone.utc).date().isoformat()

        if start or end:
            start_dt = datetime.fromisoformat(start) if start else datetime(target_year, 1, 1, tzinfo=timezone.utc)
            end_dt = datetime.fromisoformat(end) if end else end_dt
            records = _fetch_daily(symbol, start_dt, end_dt)
            merged = _merge_records(cached_data or [], records) if req.incremental else records
            payload = {
                "symbol": symbol,
                "year": target_year,
                "fetchedAt": _utc_now().isoformat(),
                "count": len(merged),
                "data": merged,
            }
            if req.store:
                _put_s3_json(key, payload)
                _update_manifest(symbol, target_year, payload)
            results.append({"symbol": symbol, "year": target_year, "count": len(merged)})

    return {"ok": True, "stored": req.store, "results": results}
