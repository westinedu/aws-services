import cors from "cors";
import express from "express";
import { z } from "zod";

import { fetchBinanceDailySeries } from "./binance.js";
import { getDailySeriesFromS3, putDailySeriesToS3 } from "./s3Store.js";

const app = express();
app.use(cors());
app.use(express.json({ limit: "1mb" }));

const QuerySchema = z.object({
  symbol: z.string().default("BTCUSDT"),
  days: z.coerce.number().int().min(1).max(365).default(90),
  maxAgeSeconds: z.coerce.number().int().min(0).max(86400).default(300),
});

function isFresh(fetchedAtIso: string, maxAgeSeconds: number) {
  const t = Date.parse(fetchedAtIso);
  if (!Number.isFinite(t)) return false;
  return Date.now() - t <= maxAgeSeconds * 1000;
}

app.get("/health", (_req, res) => {
  res.json({ ok: true, service: "btc-mindmap", ts: new Date().toISOString() });
});

/**
 * Get daily candles for last N days.
 * Strategy:
 * - Read from S3 if exists and still fresh.
 * - Otherwise fetch from Binance and overwrite S3.
 */
app.get("/api/v1/daily", async (req, res) => {
  const parsed = QuerySchema.safeParse(req.query);
  if (!parsed.success) return res.status(400).json({ error: "Invalid query", issues: parsed.error.issues });

  const { symbol, days, maxAgeSeconds } = parsed.data;

  const cached = await getDailySeriesFromS3(symbol, days);
  if (cached && isFresh(cached.fetchedAt, maxAgeSeconds)) {
    return res.json({ ...cached, source: "s3-cache" });
  }

  const fresh = await fetchBinanceDailySeries({ symbol, days });
  await putDailySeriesToS3(fresh);
  return res.json({ ...fresh, source: "binance" });
});

/**
 * Force refresh.
 */
app.post("/api/v1/daily/refresh", async (req, res) => {
  const bodySchema = z.object({
    symbol: z.string().default("BTCUSDT"),
    days: z.coerce.number().int().min(1).max(365).default(90),
  });

  const parsed = bodySchema.safeParse(req.body ?? {});
  if (!parsed.success) return res.status(400).json({ error: "Invalid body", issues: parsed.error.issues });

  const { symbol, days } = parsed.data;
  const fresh = await fetchBinanceDailySeries({ symbol, days });
  const stored = await putDailySeriesToS3(fresh);
  return res.json({ ok: true, stored, fetchedAt: fresh.fetchedAt, count: fresh.candles.length });
});

const port = Number(process.env.PORT || "8080");
app.listen(port, "0.0.0.0", () => {
  console.log(`[btc-mindmap] listening on :${port}`);
});
