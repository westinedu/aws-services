import { z } from "zod";

import type { DailyCandle, DailySeries } from "./types.js";

const BinanceKlineRow = z.tuple([
  z.number(), // open time
  z.string(), // open
  z.string(), // high
  z.string(), // low
  z.string(), // close
  z.string(), // volume
  z.number(), // close time
  z.string(), // quote asset volume
  z.number(), // number of trades
  z.string(), // taker buy base asset volume
  z.string(), // taker buy quote asset volume
  z.string(), // ignore
]);

const BinanceKlines = z.array(BinanceKlineRow);

function normalizeBinanceSymbol(raw: string) {
  const v = raw.trim().toUpperCase();
  // Conservative whitelist to avoid SSRF-style surprises.
  if (!/^[A-Z0-9]{3,20}$/.test(v)) throw new Error("Invalid symbol");
  return v;
}

export async function fetchBinanceDailySeries(opts: {
  symbol: string;
  days: number;
  baseUrl?: string;
}): Promise<DailySeries> {
  const symbol = normalizeBinanceSymbol(opts.symbol);
  const days = Math.max(1, Math.min(365, Math.floor(opts.days)));
  const baseUrl = (opts.baseUrl || process.env.BINANCE_BASE_URL || "https://api.binance.com").replace(/\/+$/, "");

  const url = new URL(baseUrl + "/api/v3/klines");
  url.searchParams.set("symbol", symbol);
  url.searchParams.set("interval", "1d");
  url.searchParams.set("limit", String(days));

  const res = await fetch(url.toString(), {
    headers: {
      "User-Agent": "btc-mindmap-service/1.0",
    },
  });

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`Binance request failed: ${res.status} ${body.slice(0, 200)}`);
  }

  const json = await res.json();
  const rows = BinanceKlines.parse(json);

  const candles: DailyCandle[] = rows.map((r) => ({
    t: r[0],
    o: Number(r[1]),
    h: Number(r[2]),
    l: Number(r[3]),
    c: Number(r[4]),
    v: Number(r[5]),
    T: r[6],
  }));

  return {
    provider: "binance",
    symbol,
    interval: "1d",
    days,
    fetchedAt: new Date().toISOString(),
    candles,
  };
}
