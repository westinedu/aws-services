"""
Simple Flask application for retrieving Bitcoin's real‑time price.

This service calls two public cryptocurrency price endpoints.  It first
tries the CoinDesk Bitcoin Price Index API (`/v1/bpi/currentprice.json`)
which returns a JSON payload with the current rate for BTC in multiple
currencies.  If the CoinDesk call fails (for example due to network
issues or API downtime) the code falls back to CoinGecko's public
`/simple/price` endpoint.  Both APIs are free and do not require API
keys.  See the NotePlan article on adding web services for templates
for an example of the CoinDesk response structure【698935379937977†L33-L58】.

The service exposes a single HTTP GET endpoint at the root (`/`).  On
success it returns a JSON object containing the price (as a float),
the currency (USD), the data source used and the last update time.
If both API calls fail the service returns a 503 response with an
error message.

To run this service locally:

    pip install -r requirements.txt
    python app.py

The application listens on port 8000 by default.
"""

from __future__ import annotations

import json
from typing import Optional, Dict, Any

import requests
from flask import Flask, jsonify, Response


app = Flask(__name__)


def _fetch_from_coindesk() -> Optional[Dict[str, Any]]:
    """Try to fetch the Bitcoin price from the CoinDesk API.

    The CoinDesk Bitcoin Price Index API returns data in the form
    explained in the NotePlan docs【698935379937977†L33-L58】.  We extract the
    USD `rate_float` field and the `updatedISO` timestamp.  If the
    request fails or the expected keys are missing, we return None.

    Returns:
        dict with keys 'price', 'currency', 'time', 'source' if
        successful, otherwise None.
    """
    url = "https://api.coindesk.com/v1/bpi/currentprice.json"
    try:
        resp = requests.get(url, timeout=5)
        resp.raise_for_status()
        data = resp.json()
        # Navigate through the nested structure to get the USD price.
        price = data["bpi"]["USD"]["rate_float"]
        timestamp = data["time"]["updatedISO"]
        return {
            "source": "coindesk",
            "currency": "USD",
            "price": price,
            "time": timestamp,
        }
    except Exception:
        # Any exception (network error, unexpected structure, etc.) results in None
        return None


def _fetch_from_coingecko() -> Optional[Dict[str, Any]]:
    """Fallback: fetch the Bitcoin price from CoinGecko.

    CoinGecko's Simple Price API returns a compact JSON mapping of
    currencies to prices.  For example
    `{"bitcoin":{"usd":30710.67}}`.  We extract the USD price.

    Returns:
        dict with keys 'price', 'currency', 'source' if successful,
        otherwise None.
    """
    url = (
        "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd"
    )
    try:
        resp = requests.get(url, timeout=5)
        resp.raise_for_status()
        data = resp.json()
        price = data["bitcoin"]["usd"]
        return {
            "source": "coingecko",
            "currency": "USD",
            "price": price,
        }
    except Exception:
        return None


def fetch_price() -> Optional[Dict[str, Any]]:
    """Attempt to fetch the current Bitcoin price from available APIs.

    We try CoinDesk first because its response includes a timestamp and
    is widely referenced in documentation【698935379937977†L33-L58】.  If that fails
    we fall back to CoinGecko.  If both fail None is returned.

    Returns:
        dict with price information or None if no API succeeds.
    """
    data = _fetch_from_coindesk()
    if data:
        return data
    return _fetch_from_coingecko()


@app.route("/", methods=["GET"])
def root() -> Response:
    """HTTP handler for the root path.

    Returns JSON with the current price data or an error message.
    """
    price_info = fetch_price()
    if price_info:
        return jsonify(price_info)
    return jsonify({"error": "Unable to fetch Bitcoin price"}), 503


if __name__ == "__main__":
    # Running in debug mode off by default.  Host '0.0.0.0' exposes
    # the service to the network; port 8000 aligns with the App Runner
    # examples and the Dockerfile port.
    app.run(host="0.0.0.0", port=8000)