import cors from "cors";
import express from "express";
import swaggerUi from "swagger-ui-express";
import { z } from "zod";

import { fetchDailySeriesWithFallback } from "./binance.js";
import { getDailySeriesFromS3, putDailySeriesToS3 } from "./s3Store.js";

const app = express();
app.use(cors());
app.use(express.json({ limit: "1mb" }));

function asyncHandler(
  fn: (req: express.Request, res: express.Response, next: express.NextFunction) => Promise<any>
) {
  return (req: express.Request, res: express.Response, next: express.NextFunction) => {
    Promise.resolve(fn(req, res, next)).catch(next);
  };
}

const QuerySchema = z.object({
  symbol: z.string().default("BTCUSDT"),
  days: z.coerce.number().int().min(1).max(365).default(90),
  maxAgeSeconds: z.coerce.number().int().min(0).max(86400).default(300),
});

function isS3Enabled() {
  const v = (process.env.MARKETDATA_DISABLE_S3 || "").trim().toLowerCase();
  if (v === "1" || v === "true" || v === "yes") return false;

  // If no bucket is configured, silently disable S3 so local dev works out of the box.
  const bucket = (process.env.MARKETDATA_S3_BUCKET || process.env.S3_BUCKET || "").trim();
  if (!bucket) return false;

  return true;
}

function isFresh(fetchedAtIso: string, maxAgeSeconds: number) {
  const t = Date.parse(fetchedAtIso);
  if (!Number.isFinite(t)) return false;
  return Date.now() - t <= maxAgeSeconds * 1000;
}

app.get("/", (_req, res) => {
  res.redirect("/docs");
});

app.get("/health", (_req, res) => {
  res.json({ ok: true, service: "btc-mindmap", ts: new Date().toISOString() });
});

const swaggerDoc = {
  openapi: "3.0.1",
  info: {
    title: "BTC Mindmap Service",
    version: "1.0.0",
    description: "Daily candle data with optional S3 caching.",
  },
  servers: [{ url: "/" }],
  paths: {
    "/health": {
      get: {
        summary: "Health check",
        responses: { 200: { description: "OK" } },
      },
    },
    "/api/v1/daily": {
      get: {
        summary: "Get daily candles",
        parameters: [
          { name: "symbol", in: "query", schema: { type: "string", default: "BTCUSDT" } },
          { name: "days", in: "query", schema: { type: "integer", minimum: 1, maximum: 365, default: 90 } },
          {
            name: "maxAgeSeconds",
            in: "query",
            schema: { type: "integer", minimum: 0, maximum: 86400, default: 300 },
          },
        ],
        responses: { 200: { description: "Daily candles" }, 400: { description: "Invalid query" } },
      },
    },
    "/api/v1/daily/refresh": {
      post: {
        summary: "Force refresh daily candles",
        requestBody: {
          required: false,
          content: {
            "application/json": {
              schema: {
                type: "object",
                properties: {
                  symbol: { type: "string", default: "BTCUSDT" },
                  days: { type: "integer", minimum: 1, maximum: 365, default: 90 },
                },
              },
            },
          },
        },
        responses: { 200: { description: "Refreshed" }, 400: { description: "Invalid body" } },
      },
    },
  },
};

app.use("/docs", swaggerUi.serve, swaggerUi.setup(swaggerDoc));
app.get("/openapi.json", (_req, res) => res.json(swaggerDoc));

/**
 * Get daily candles for last N days.
 * Strategy:
 * - Read from S3 if exists and still fresh.
 * - Otherwise fetch from Binance and overwrite S3.
 */
app.get(
  "/api/v1/daily",
  asyncHandler(async (req, res) => {
  const parsed = QuerySchema.safeParse(req.query);
  if (!parsed.success) return res.status(400).json({ error: "Invalid query", issues: parsed.error.issues });

  const { symbol, days, maxAgeSeconds } = parsed.data;

  const s3Enabled = isS3Enabled();
  if (s3Enabled) {
    const cached = await getDailySeriesFromS3(symbol, days);
    if (cached && isFresh(cached.fetchedAt, maxAgeSeconds)) {
      return res.json({ ...cached, source: "s3-cache" });
    }
  }

  const fresh = await fetchDailySeriesWithFallback({ symbol, days });
  if (s3Enabled) await putDailySeriesToS3(fresh);
  return res.json({ ...fresh, source: "upstream" });
  })
);

/**
 * Force refresh.
 */
app.post(
  "/api/v1/daily/refresh",
  asyncHandler(async (req, res) => {
  const bodySchema = z.object({
    symbol: z.string().default("BTCUSDT"),
    days: z.coerce.number().int().min(1).max(365).default(90),
  });

  const parsed = bodySchema.safeParse(req.body ?? {});
  if (!parsed.success) return res.status(400).json({ error: "Invalid body", issues: parsed.error.issues });

  const { symbol, days } = parsed.data;
  const fresh = await fetchDailySeriesWithFallback({ symbol, days });
  const stored = isS3Enabled() ? await putDailySeriesToS3(fresh) : null;
  return res.json({ ...fresh, source: "upstream", refreshed: true, stored });
  })
);

app.use((err: any, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
  const message = err instanceof Error ? err.message : String(err);
  console.error("[btc-mindmap] request failed:", message);
  return res.status(502).json({ error: "Upstream fetch failed", message: message.slice(0, 500) });
});

const port = Number(process.env.PORT || "8080");
app.listen(port, "0.0.0.0", () => {
  console.log(`[btc-mindmap] listening on :${port}`);
});
