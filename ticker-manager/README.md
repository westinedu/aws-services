Ticker Manager

This standalone tool fetches tickers from Wikipedia for S&P 500, Dow Jones, and Nasdaq-100, merges and deduplicates them, saves a JSON file, and optionally uploads it to S3.

Quick start

Install dependencies (preferably in a virtualenv):

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Generate JSON locally:

```bash
python3 ticker_manager.py --generate --output us_tickers.json
```

Generate and upload to S3:

```bash
python3 ticker_manager.py --generate --output us_tickers.json --upload --bucket my-bucket --object path/us_tickers.json
```

If you encounter SSL certificate issues, you can disable verification (not recommended):

```bash
python3 ticker_manager.py --generate --output us_tickers.json --insecure
```
