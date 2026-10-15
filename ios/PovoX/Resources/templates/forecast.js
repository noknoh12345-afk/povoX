// title: なくなる前にデータを足す
// summary: 今のペースで2時間以内になくなりそうなら、1GBあたり最安のデータ追加を買う(使い放題は買わない)。

const SOON_HOURS = 2;

function decide(ctx) {
  const d = ctx.data;
  const f = ctx.forecast;
  if (d.leftGB == null || d.unlimited.active) return skip("残量不明か使い放題中");
  if (f.hoursLeft == null || f.hoursLeft >= SOON_HOURS) {
    return skip(`このペースならあと${f.hoursLeft == null ? "十分" : f.hoursLeft.toFixed(1) + "時間"}もちます`);
  }
  const best = ctx.catalog()
    .filter(p => !p.unlimited && p.gb != null && p.price != null && !p.requires3ds)
    .sort((a, b) => a.price / a.gb - b.price / b.gb)[0];
  return firstOf(
    applyCode(),
    buy(best),
    notify("povo もうすぐなくなります", `あと約${f.hoursLeft.toFixed(1)}時間`)
  );
}
