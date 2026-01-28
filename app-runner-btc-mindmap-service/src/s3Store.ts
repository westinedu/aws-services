import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";

import type { DailySeries } from "./types.js";

function getRegion() {
  return (process.env.AWS_REGION || process.env.S3_REGION || "us-east-1").trim();
}

function getBucket() {
  const bucket = (process.env.MARKETDATA_S3_BUCKET || process.env.S3_BUCKET || "").trim();
  if (!bucket) throw new Error("Missing MARKETDATA_S3_BUCKET (or S3_BUCKET)");
  return bucket;
}

function getPrefix() {
  const p = (process.env.MARKETDATA_S3_PREFIX || "market-data").trim().replace(/^\/+|\/+$/g, "");
  return p;
}

function getEndpoint() {
  const v = (process.env.S3_ENDPOINT || "").trim();
  return v || undefined;
}

function getForcePathStyle() {
  const v = (process.env.S3_FORCE_PATH_STYLE || "").trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes";
}

export const s3Client = new S3Client({
  region: getRegion(),
  endpoint: getEndpoint(),
  forcePathStyle: getForcePathStyle(),
});

function bodyToString(body: any): Promise<string> {
  if (!body) return Promise.resolve("");
  if (typeof body.transformToString === "function") return body.transformToString();
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    body.on("data", (c: Buffer) => chunks.push(c));
    body.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    body.on("error", reject);
  });
}

export function dailySeriesKey(symbol: string, days: number) {
  return `${getPrefix()}/daily/${symbol.toLowerCase()}/last_${days}d.json`;
}

export async function getDailySeriesFromS3(symbol: string, days: number): Promise<DailySeries | null> {
  const Bucket = getBucket();
  const Key = dailySeriesKey(symbol, days);

  try {
    const res = await s3Client.send(new GetObjectCommand({ Bucket, Key }));
    const raw = await bodyToString(res.Body);
    if (!raw) return null;
    return JSON.parse(raw) as DailySeries;
  } catch (e: any) {
    const name = String(e?.name || "");
    const code = String(e?.$metadata?.httpStatusCode || "");
    if (name.includes("NoSuchKey") || code === "404") return null;
    return null;
  }
}

export async function putDailySeriesToS3(series: DailySeries): Promise<{ bucket: string; key: string }> {
  const Bucket = getBucket();
  const Key = dailySeriesKey(series.symbol, series.days);

  await s3Client.send(
    new PutObjectCommand({
      Bucket,
      Key,
      Body: JSON.stringify(series),
      ContentType: "application/json",
      CacheControl: "public, max-age=30",
    })
  );

  return { bucket: Bucket, key: Key };
}
