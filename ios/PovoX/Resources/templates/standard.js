// title: 標準(コード → 使い放題)
// summary: 残りが少ないか、なくなりそうなら、手持ちのコードを使い、無ければ使い放題を買う。電池が少ないときは1時間だけ。

const LOW_GB = 0.5;       // 残りがこれを切ったら動く
const SOON_HOURS = 3;     // このペースだとこの時間以内になくなりそうなら動く
const BATTERY_LOW = 20;   // 電池がこれ以下(充電していない)なら、短い使い放題にする

function decide(ctx) {
  const d = ctx.data;
  if (ctx.network === "wifi") return skip("Wi-Fi なので何もしない");
  if (d.leftGB == null) return skip("残量を読めませんでした");
  if (d.unlimited.active) return skip("使い放題中");

  const soon = ctx.forecast.hoursLeft != null && ctx.forecast.hoursLeft < SOON_HOURS;
  if (d.leftGB >= LOW_GB && !soon) return skip(`残り ${d.leftGB.toFixed(2)}GB`);

  const lowBattery = ctx.battery.level != null && ctx.battery.level <= BATTERY_LOW && !ctx.battery.charging;
  const hours = lowBattery ? 1 : 24;
  return firstOf(
    applyCode(),                                                          // 1. 手持ちのコード
    buy(cheapest(ctx.catalog(), p => p.unlimited && p.hours === hours)),  // 2. 使い放題
    notify("povo 残りわずか", `残り ${d.leftMB.toFixed(0)}MB`)              // 3. どれもできなければ知らせる
  );
}
