// title: コードだけ使う
// summary: 残りが少なくなったら手持ちのコードを使う。買い物はしない。コードが無ければ知らせるだけ。

const LOW_GB = 0.3;

function decide(ctx) {
  const d = ctx.data;
  if (d.leftGB == null || d.unlimited.active) return skip("残量不明か使い放題中");
  if (d.leftGB >= LOW_GB) return skip(`残り ${d.leftGB.toFixed(2)}GB`);
  return firstOf(
    applyCode(),
    notify("povo 残りわずか", `残り ${d.leftMB.toFixed(0)}MB。手持ちのコードがありません`)
  );
}
