// title: 知らせるだけ
// summary: 何も買わない・使わない。残りが少ないとき、使い放題がもうすぐ終わるときに通知する。

function decide(ctx) {
  const d = ctx.data;
  if (d.unlimited.active && d.unlimited.hoursLeft != null && d.unlimited.hoursLeft < 0.5) {
    return notify("使い放題がもうすぐ終わります", `あと約${Math.round(d.unlimited.hoursLeft * 60)}分`);
  }
  if (d.leftGB != null && !d.unlimited.active && d.leftGB < 0.5) {
    return notify("povo 残りわずか", `残り ${d.leftMB.toFixed(0)}MB`);
  }
  return skip("知らせることはありません");
}
