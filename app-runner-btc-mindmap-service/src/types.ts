export type DailyCandle = {
  t: number; // open time (ms)
  T: number; // close time (ms)
  o: number;
  h: number;
  l: number;
  c: number;
  v: number; // base asset volume
};

export type DailySeries = {
  provider: "binance";
  symbol: string;
  interval: "1d";
  days: number;
  fetchedAt: string;
  candles: DailyCandle[];
};
