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

function isRestrictedLocationError(message: string) {
  return /restricted location/i.test(message) || /Service unavailable from a restricted location/i.test(message);
}

const KrakenOhlcRow = z.tuple([
  z.number(), // time (s)
  z.string(), // open
  z.string(), // high
  z.string(), // low
  z.string(), // close
  z.string(), // vwap
  z.string(), // volume
  z.number(), // count
]);

const KrakenOhlcResponse = z.object({
  error: z.array(z.string()),
  result: z.record(z.any()),
});

const CoinbaseCandleRow = z.tuple([
  z.number(), // time (s)
  z.number(), // low
  z.number(), // high
  z.number(), // open
  z.number(), // close
  z.number(), // volume
]);

function normalizeSymbolForFallback(raw: string) {
  const v = raw.trim().toUpperCase();
  if (!/^[A-Z0-9]{3,20}$/.test(v)) throw new Error("Invalid symbol");
  return v;
}

function mapToBaseQuote(symbol: string): { base: string; quote: string } | null {
  // Minimal parser for symbols like BTCUSDT / ETHUSDT / BTCUSD.
  const m = symbol.match(/^([A-Z0-9]{2,10})(USDT|USD)$/);
  if (!m) return null;
  return { base: m[1], quote: m[2] };
}

function unixSecondsFromDaysAgo(days: number) {
  const nowSec = Math.floor(Date.now() / 1000);
  return nowSec - Math.max(1, Math.min(365, Math.floor(days))) * 86400;
}

async function fetchKrakenDailySeries(opts: { symbol: string; days: number }): Promise<DailySeries> {
  const symbol = normalizeSymbolForFallback(opts.symbol);
  const days = Math.max(1, Math.min(365, Math.floor(opts.days)));

  const bq = mapToBaseQuote(symbol);
  if (!bq) throw new Error("Kraken fallback only supports symbols like BTCUSDT/BTCUSD");

  const base = bq.base === "BTC" ? "XBT" : bq.base;
  const preferredPairs = bq.quote === "USDT" ? [`${base}USDT`, `${base}USD`] : [`${base}USD`];
  const since = unixSecondsFromDaysAgo(days + 2);

  let lastErr: unknown;
  for (const pair of preferredPairs) {
    const url = new URL("https://api.kraken.com/0/public/OHLC");
    url.searchParams.set("pair", pair);
    url.searchParams.set("interval", "1440");
    url.searchParams.set("since", String(since));

    try {
      const res = await fetch(url.toString(), { headers: { "User-Agent": "btc-mindmap-service/1.0" } });
      const json = await res.json();
      const parsed = KrakenOhlcResponse.parse(json);
      if (parsed.error.length) throw new Error(`Kraken error: ${parsed.error.join(", ")}`);

      const resultObj = parsed.result as Record<string, unknown>;
      const key = Object.keys(resultObj).find((k) => k.toLowerCase().includes(pair.toLowerCase())) ?? pair;
      const rowsAny = (resultObj[key] ?? resultObj[pair]) as unknown;
      const rows = z.array(KrakenOhlcRow).parse(rowsAny);

      const trimmed = rows.slice(-days);
      const candles: DailyCandle[] = trimmed.map((r) => {
        const openMs = r[0] * 1000;
        return {
          t: openMs,
          T: openMs + 86400000 - 1,
          o: Number(r[1]),
          h: Number(r[2]),
          l: Number(r[3]),
          c: Number(r[4]),
          v: Number(r[6]),
        };
      });

      return {
        provider: "kraken",
        symbol,
        interval: "1d",
        days,
        fetchedAt: new Date().toISOString(),
        candles,
      };
    } catch (e) {
      lastErr = e;
    }
  }

  throw lastErr instanceof Error ? lastErr : new Error("Kraken request failed");
}

async function fetchCoinbaseDailySeries(opts: { symbol: string; days: number }): Promise<DailySeries> {
  const symbol = normalizeSymbolForFallback(opts.symbol);
  const days = Math.max(1, Math.min(365, Math.floor(opts.days)));
  const bq = mapToBaseQuote(symbol);
  if (!bq) throw new Error("Coinbase fallback only supports symbols like BTCUSDT/BTCUSD");

  // Coinbase Exchange uses BTC-USD style; treat USDT ~ USD for daily candles.
  const productId = `${bq.base}-USD`;

  const url = new URL(`https://api.exchange.coinbase.com/products/${encodeURIComponent(productId)}/candles`);
  url.searchParams.set("granularity", "86400");

  const res = await fetch(url.toString(), { headers: { "User-Agent": "btc-mindmap-service/1.0" } });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`Coinbase request failed: ${res.status} ${body.slice(0, 200)}`);
  }

  const json = await res.json();
  const rows = z.array(CoinbaseCandleRow).parse(json);
  // Coinbase returns newest-first
  const newestFirst = rows.slice(0, days);
  const asc = newestFirst.slice().reverse();
  const candles: DailyCandle[] = asc.map((r) => {
    const openMs = r[0] * 1000;
    return {
      t: openMs,
      T: openMs + 86400000 - 1,
      o: r[3],
      h: r[2],
      l: r[1],
      c: r[4],
      v: r[5],
    };
  });

  return {
    provider: "coinbase",
    symbol,
    interval: "1d",
    days,
    fetchedAt: new Date().toISOString(),
    candles,
  };
}

export async function fetchDailySeriesWithFallback(opts: { symbol: string; days: number }): Promise<DailySeries> {
  const symbol = normalizeSymbolForFallback(opts.symbol);
  const days = Math.max(1, Math.min(365, Math.floor(opts.days)));

  // 1) Binance.com
  try {
    return await fetchBinanceDailySeries({ symbol, days });
  } catch (e: any) {
    const msg = e?.message ? String(e.message) : String(e);

    // 2) Binance.US (commonly works where binance.com is blocked)
    // Only attempt when we detect the common restriction or explicit 451.
    if (msg.includes(" 451 ") || isRestrictedLocationError(msg)) {
      try {
        const baseUrl = (process.env.BINANCE_US_BASE_URL || "https://api.binance.us").replace(/\/+$/, "");
        const s = await fetchBinanceDailySeries({ symbol, days, baseUrl });
        return { ...s, provider: "binance-us" };
      } catch {
        // fallthrough
      }
    }

    // 3) Kraken
    try {
      return await fetchKrakenDailySeries({ symbol, days });
    } catch {
      // fallthrough
    }

    // 4) Coinbase
    return await fetchCoinbaseDailySeries({ symbol, days });
  }
}
