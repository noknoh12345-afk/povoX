// title: 夜は買わない
// summary: 標準と同じだが、0時〜7時は買わずに知らせるだけ(寝ている間の無駄な購入を防ぐ)。

const LOW_GB = 0.5;

function decide(ctx) {
  const d = ctx.data;
  if (ctx.network === "wifi") return skip("Wi-Fi なので何もしない");
  if (d.leftGB == null || d.unlimited.active) return skip("残量不明か使い放題中");
  if (d.leftGB >= LOW_GB) return skip(`残り ${d.leftGB.toFixed(2)}GB`);

  const night = ctx.now.hour < 7;
  if (night) return notify("povo 残りわずか(夜間)", `残り ${d.leftMB.toFixed(0)}MB。朝になったら補充します`);
  return firstOf(
    applyCode(),
    buy(cheapest(ctx.catalog(), p => p.unlimited && p.hours === 24)),
    notify("povo 残りわずか", `残り ${d.leftMB.toFixed(0)}MB`)
  );
}
