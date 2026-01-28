#!/usr/bin/env bash
set -euo pipefail

TRADING_BASE_URL="${TRADING_BASE_URL:-https://jwep53paj2.us-east-2.awsapprunner.com}"
SYMBOLS_RAW="${SYMBOLS:-${SYMBOL:-AAPL,MSFT,GOOGL,AMZN,META,NVDA,AMD,TSLA,AVGO,NFLX}}"
BATCH_SIZE="${BATCH_SIZE:-1}"
SLEEP_SECONDS="${SLEEP_SECONDS:-1}"

BASE_URL="${TRADING_BASE_URL%/}"

IFS=',' read -r -a SYMBOLS <<< "$SYMBOLS_RAW"

# Build year list: current year and previous 4 years
YEARS_JSON=$(python3 - <<'PY'
from datetime import datetime, UTC
now = datetime.now(UTC)
years = [now.year - i for i in range(5)]
print(" ".join(str(y) for y in years))
PY
)

TODAY=$(python3 - <<'PY'
from datetime import datetime, UTC
print(datetime.now(UTC).strftime('%Y-%m-%d'))
PY
)

for year in $YEARS_JSON; do
  if [[ "$year" == "$(date -u +%Y)" ]]; then
    END_DATE="$TODAY"
  else
    END_DATE="$year-12-31"
  fi

  idx=0
  while [[ $idx -lt ${#SYMBOLS[@]} ]]; do
    batch=("${SYMBOLS[@]:$idx:$BATCH_SIZE}")
    payload=$(python3 - "$year" "$END_DATE" "${batch[@]}" <<'PY'
import json
import sys

year = int(sys.argv[1])
end_date = sys.argv[2]
symbols = [s.strip().upper() for s in sys.argv[3:] if s.strip()]

print(json.dumps({
  "symbols": symbols,
  "incremental": False,
  "fillYear": True,
  "year": year,
  "end": end_date
}))
PY
)

    echo "Backfill year=$year end=$END_DATE symbols=${batch[*]}"
    curl -sS -X POST "$BASE_URL/api/v1/stocks/refresh" \
      -H 'accept: application/json' \
      -H 'Content-Type: application/json' \
      -d "$payload" \
      | cat
    echo ""

    if [[ "$SLEEP_SECONDS" -gt 0 ]]; then
      sleep "$SLEEP_SECONDS"
    fi

    idx=$((idx + BATCH_SIZE))
  done
done
