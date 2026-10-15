# povoX

povo2.0 のデータ残量を取りつづけ、条件に合わせて **手持ちコードの自動入力・トッピングの自動購入・使い放題の適用** を行う iPhone アプリ(非公式)。判断は **JavaScript のルール** で自由に書けます。

KDDI・povo・Circles.life とは無関係です。povo への通信は、povo-web と同じく公開ライブラリ [uirooong/povo-core](https://github.com/uirooong/povo-core)(MIT)をそのまま使い、送る値は povo-android と同じです。

## 入れ方(Mac から)

1. GitHub の **Releases** から最新の `povoX.ipa` をダウンロードする(Actions の Artifacts にもあります)。
2. Mac に [Sideloadly](https://sideloadly.io/) を入れ、iPhone を USB でつなぐ。
3. Sideloadly に `povoX.ipa` をドラッグし、自分の Apple ID を入れて「Start」。
4. iPhone で次の2つを許可する。
   - 設定 → 一般 → VPNとデバイス管理 → 自分の Apple ID を「信頼」
   - 設定 → プライバシーとセキュリティ → **デベロッパモード** をオン(再起動あり)
5. 設定 → 一般 → **Appのバックグラウンド更新** で povoX をオンにする。

無料の Apple ID で署名した場合、7日ごとに入れ直し(Sideloadly の自動更新でも可)が必要です。入れ直してもデータとログインは残ります。

## 最初にやること(おすすめ順)

1. 設定タブ(ログイン前はログイン画面の下)で **モック** をオンにし、認証コード `000000` でログイン。画面・ルール・安全装置を作り物のデータで試す。
2. モックをオフにして本番でログイン(メールか SMS の認証コード)。残量と「ご利用中のトッピング」が公式アプリと一致するか見る。
3. 「コード」タブに手持ちのコードを登録(1行に `コード タグ メモ`)。
4. 「自動化」タブで **試運転** を押し、ログに「〜するところでした」と期待どおり出るか確かめる。
5. 月の上限・1日の回数・間隔を決めてから、**試運転をオフ** にする。
6. ショートカットのオートメーションを登録する(下)。

## 「常に取得」について(iOS の制約)

iOS はアプリを常に裏で動かせないので、次の3つを組み合わせます。

| きっかけ | 確実さ | 備考 |
| --- | --- | --- |
| ショートカットのオートメーション | ◎ | バッテリー残量・充電器・時刻・Wi-Fi 切断・App を開いた時など。iOS 17 以降は「すぐに実行」で確認なし |
| バックグラウンド更新 | △ | 間隔(既定30分)は目安。iOS の判断で数時間空くことがある |
| アプリを開いている間 | ○ | 間隔ごとに自動チェック |

### ショートカットの登録

ショートカット App → オートメーション → 「+」→ きっかけを選ぶ → 「すぐに実行」→ アクションに **「povoXの自動チェック」** を追加。「きっかけ」に文字を入れると、ルールの `ctx.trigger` に入ります(例: `battery-low`)。

「povoXのデータ残量」アクションは残り GB を数値で返すので、ショートカット側の条件分岐にも使えます。

## ルール(JavaScript)

`function run(ctx) { … }` が自動チェックのたびに呼ばれます。最初から入っているルールは:

- Wi-Fi のときは何もしない
- 残り 0.5GB を切ったら、まず手持ちのコードを1件使う
- コードが無ければ、**電池が 20% 以下で充電していないときは1時間の使い放題、それ以外は24時間の使い放題** を買う

使えるもの(アプリの「スクリプトの使い方」にも同じ説明があります):

```js
ctx.trigger / ctx.battery {level, charging, full, lowPower} / ctx.network ("wifi" | "cellular" | …)
ctx.now {hour, minute, weekday, date} / ctx.lastRun / ctx.dryRun

povo.usage()          // { leftGB, leftMB, buckets, toppings, unlimitedActive, … }
povo.catalog()        // [{ sku, name, price, validity, requires3ds, … }]
povo.find(/使い放題/)  // 名前で探す(安い順)
povo.buy(product)     // 自動購入 → { ok, dryRun, needs3ds, message }
povo.codes("1gb")     // 未使用コード
povo.applyCode("1gb") // コードを1件適用 → { ok, dryRun, valid, message }
povo.budget()         // { capYen, spentYen, remainingYen, … }
log(…) / notify(題名, 本文) / state.get(k, 既定) / state.set(k, v)
```

## 安全装置(ルールからは外せません)

povo-web の約束ごとをそのまま引き継ぎ、自動化のぶんを足しています。

- povo への通信は常に1本ずつ、自動リトライなし。403 や PIN 要求が返ったら **アプリで「通信を再開」を押すまで自動チェックも含めて全部止まる**。povo が待機時刻を返したら、その時刻まで送らない。
- トークンの更新は期限切れ後だけ。端末IDとトークンは組でキーチェーンに保存(この端末だけ・最初のロック解除後に読める)。
- **自動購入**は「試運転オフ」「月の上限金額」「1日の回数」「前回からの間隔」「購入できる一覧に載っている」「3Dセキュア不要」「価格が読める」をすべて満たすときだけ。同じ商品は2分以内に重ねて注文しない。
- **コード**は送る前に「送信済み」にし、二度と自動では送らない。15秒に1回まで。データ使い放題の有効期間中は送らない(公式アプリの注意書き)。トッピングを読めず使い放題中か分からないときも自動では送らない。
- povo への通信は5分間に20回まで(ルールの書き間違いで連打しないため)。残量は30秒以内なら前回の値、購入一覧は6時間使い回す。
- 購入・コード送信の結果が失敗でも、povo 側で処理された可能性があるので、購入履歴で確かめてください。

## 未確認のこと

- コード適用(`promotions/code/set`)は povo-web と同じく **実アカウントでは未検証**。最初は手持ちの1件で手動で試してください。
- 3Dセキュアを最後まで通す経路は povo-android の作者も未検証。povoX は3DSが要る商品を自動では買いません(手動購入では認証画面を開きます)。
- 「1時間の使い放題」が今の povo の購入一覧にあるかは、アカウントや時期で変わります。無ければルールは「商品なし」と通知します。

## 構成

```
core/                      Rust のエンジン(povo-core を利用)。安全装置・記録・コード管理
  src/engine.rs            操作・安全装置・保存
  src/backend.rs parse.rs protocol.rs mock.rs   povo-web からそのまま流用
  src/lib.rs               iOS への入口(C 関数2つ、JSON でやり取り)
ios/                       SwiftUI アプリ(XcodeGen の project.yml)
  PovoX/Automation/        JavaScript ルールの実行・バックグラウンド更新・ショートカット
.github/workflows/build.yml  macOS で core を iOS 向けにビルド → アプリをビルド → 未署名 IPA
tools/script-harness.js    ルールをパソコン上でモックのエンジンにつないで試す
```

開発:

```sh
cd core && cargo test                 # エンジンのテスト(モック、povo に通信しない)
cargo build --example cli
node tools/script-harness.js /tmp/st  # 既定のルールをモックで1回動かす
```
