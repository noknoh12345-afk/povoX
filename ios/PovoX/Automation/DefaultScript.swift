import Foundation

enum DefaultScript {
    static let text = #"""
    // povoX 自動ルール
    // run(ctx) が「自動チェック」のたびに呼ばれます
    // (バックグラウンド更新 / ショートカット / アプリ表示中 / 手動)。
    // 最初は「試運転」なので、購入・コード適用は実際には行われません。
    // ログに「〜するところでした」と出るのを確かめてから、設定で試運転を切ってください。

    const LOW_GB = 0.5;       // 残りがこれを切ったら動く
    const BATTERY_LOW = 20;   // 電池がこれ以下(充電していない)なら、短い使い放題にする

    function run(ctx) {
      // Wi-Fi のときはモバイル通信を使っていないので何もしない
      if (ctx.network === "wifi") return "Wi-Fi なので何もしません";

      const d = povo.usage();
      if (d.leftGB == null) return "残量を読めませんでした";
      log(`残り ${d.leftGB.toFixed(2)}GB / 電池 ${ctx.battery.level ?? "?"}%`);

      if (d.unlimitedActive) return "使い放題中";
      if (d.leftGB >= LOW_GB) return `残り ${d.leftGB.toFixed(2)}GB`;

      // 1) 手持ちのコードがあれば、まずそれを使う
      if (povo.codes().length > 0) {
        const r = povo.applyCode();
        notify("povo: コード適用", r.message);
        return r.message;
      }

      // 2) 電池が少ないときは、長い使い放題は無駄になりやすいので1時間だけ
      const batteryLow = ctx.battery.level != null
        && ctx.battery.level <= BATTERY_LOW && !ctx.battery.charging;
      const want = batteryLow ? /使い放題.*1時間/ : /使い放題.*24時間/;
      const p = povo.find(want).filter(x => !x.requires3ds)[0];
      if (!p) {
        notify("povo: 残りわずか", `残り ${d.leftMB.toFixed(0)}MB。条件に合う商品がありません`);
        return "商品なし";
      }
      const r = povo.buy(p);
      notify("povo: " + p.name, r.message);
      return r.message;
    }
    """#

    /// 「使い方」に出す説明。
    static let help = #"""
    ■ run(ctx) に渡されるもの
    ctx.trigger   きっかけ: "background" "shortcut" "foreground" "manual" "test"
                  (ショートカットで「きっかけ」に好きな文字を入れるとそれが入る)
    ctx.battery   { level: 0〜100 または null, charging, full, lowPower }
    ctx.network   "wifi" / "cellular" / "wired" / "none" / "unknown"
    ctx.now       { hour, minute, weekday(0=日), date: "YYYY-MM-DD", ms }
    ctx.lastRun   前回の実行時刻(ミリ秒)または null
    ctx.dryRun    試運転中なら true
    ctx.mock      モック(povo に通信しない)なら true

    ■ povo
    povo.usage()            残量を取得(30秒以内なら前回の値)。{ force: true } で取り直す
      → { leftGB, leftMB, buckets[{key,label,leftGB,usedGB,planGB}],
          toppings[{section,name,remaining,expiry}],
          unlimitedActive(true/false/読めなければ null), unlimited, fetchedAt, cached }
    povo.catalog()          購入できるトッピング一覧(6時間キャッシュ)
      → [{ sku, name, price(円), priceText, validity, section, requires3ds }]
    povo.find(/正規表現/ or "文字")  一覧から名前で探す(安い順)
    povo.buy(商品 or sku)   自動購入 → { ok, dryRun, needs3ds, message }
    povo.codes(タグ?)       未使用の手持ちコード → [{ id, tag, note, masked }]
    povo.applyCode(タグ?)   未使用コードを1件適用 → { ok, dryRun, valid, message }
    povo.budget()           { capYen, spentYen, remainingYen, todayCount, maxPerDay }
    povo.dryRun             試運転中なら true

    ■ その他
    log(...)                ログに書く(最後の log が結果の要約になる)
    notify(題名, 本文)       通知を出す
    state.get(キー, 既定値) / state.set(キー, 値)   実行をまたいで値を残す
    return "文字"           その文字が結果の要約になる(ショートカットにも返る)

    ■ 必ずかかる安全装置(スクリプトからは外せません)
    ・自動購入: 試運転 / 月の上限金額 / 1日の回数 / 間隔 / 3Dセキュア不要の商品だけ
    ・同じ商品は2分以内に重ねて注文しない
    ・コード: 送ったコードは二度と自動では送らない / 15秒に1回まで /
      データ使い放題の有効期間中は送らない
    ・povo への通信は5分間に20回まで。403 などが返ったら全部止まり、アプリで「再開」を押すまで動かない
    """#
}
