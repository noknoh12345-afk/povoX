# 実装プロンプト集(v3 の独自機能)

[PLAN.md](PLAN.md) の 16 機能を、そのまま着手できる形にした指示。1 プロンプト = 1 機能。
各プロンプトは独立して実行でき、最後に CI(`.github/workflows/build.yml`)を通して緑にする。

共通の前提(全プロンプトに効く):
- リポジトリは `povoX`。Rust エンジンは `core/`(UniFFI で Swift に型付き API)、アプリは `ios/`(SwiftUI + XcodeGen)。
- 通信は povo-core 経由のみ。お金が動く操作は既存の安全装置を必ず通す。勝手に新しい送信先を作らない。
- エンジンに公開メソッドを足したら `#[uniffi::export]` に載せ、`core/src/mock.rs` に作り物のデータ、`core/src/tests.rs` にテストを足す。`cd core && cargo test --lib` が通ること。
- Swift の新しい型/メソッドは CI がバインディングを再生成する(`ios/Generated` は .gitignore)。
- 拡張(ウィジェット・Live Activity)が絡む機能は `Runtime`(`ios/PovoX/App/Runtime.swift`)で Mac/LiveContainer を見分け、使えないときは非表示にする。
- コミット末尾の属性行は、その時点の指示に従う。

---

## Wave 4 — まず見てすぐ分かるもの(主に Swift)

### A3. ペース比較(今日は普段の何倍)
**目的**: 「今日の使い方が普段より多い/少ない」を一目で。
**変更**: `ios/PovoX/Views/Home/HomeView.swift` に小さな指標カード。必要なら `ios/PovoX/Core/Formatting.swift`。
**仕様**: `store.insights`(`UsageInsights`)の `usedTodayKb` と `used7dKb/7` を比べ、倍率(例「今日は普段の 1.8 倍」)と、今日/平均の MB を出す。平均が 0 や欠損のときは「比べるデータがまだありません」。使い放題中・残量不明のときは控える。
**テスト**: `PovoXTests` に、倍率計算のヘルパー(Swift 側に純関数として切り出す)の単体テスト。
**受け入れ**: ホームに指標が出る。モックで普段より多い/少ない両方の表示をスクショ(`PovoXUITests`)。

### A6. 月末着地予測(データ量・支出)
**目的**: 「このままだと今月、データをどれだけ使う/いくら使う」。
**変更**: 新 `ios/PovoX/Views/Money/MoneyView.swift`(お金の画面。C1 と同居)か、ホームのカード。計算は Swift の純関数 `Projection`。
**仕様**: データ=`insights.kbPerHour × 月末までの残り時間 + これまでの今月使用`。支出=`budget.allSpentYen` と、直近の購入ペースからの推定(控えめに。不明なら「予測なし」)。JST の月末は `now` から計算。
**テスト**: `Projection` の純関数テスト(既知の入力→既知の出力)。
**受け入れ**: 数値が出る。データが足りないときは素直に「予測なし」。

### C1. 月の支出サマリー＋予算バー
**目的**: 今月いくら使ったか・上限までどれだけか。
**変更**: `MoneyView.swift`(新規)。設定からの導線(`SettingsView` の「アカウント」付近に「お金」リンク)。
**仕様**: `store` に `budget`(`Budget`)がある。上限(`capYen`)・今月の支出(`allSpentYen`・ルール分 `ruleSpentYen`)・残り(`remainingYen`)・今日の回数(`ruleOrdersToday`/`maxPerDay`)をバーと数値で。`ledger`(最近の注文)も一覧で。
**テスト**: 既存の `budget()` テストで足りる。表示はスクショ。
**受け入れ**: 予算バーと今月の支出が出る。モックでスクショ。

### B4. 残量シェアカード画像
**目的**: 残量・予測をきれいなカード画像にして共有。
**変更**: `ios/PovoX/Views/Home/ShareCard.swift`(新規)。ホームに共有ボタン。
**仕様**: SwiftUI で残量・あと何時間・日付のカードを作り、`ImageRenderer`(iOS 16+)で `UIImage`→一時 PNG→共有シート(`ShareSheet` は `AccountViews.swift` に既存)。個人情報(電話番号等)は出さない。
**テスト**: カードビューが生成できること(スナップショットは任意)。
**受け入れ**: 共有ボタンから画像が共有できる。

---

## Wave 5 — 使い方の可視化(エンジン追加)

### A2. 使用ヒートマップ(曜日×時間帯)
**目的**: いつ一番使うかを 7×24 の濃淡で。
**変更(エンジン)**: `core/src/history.rs` に `heatmap(history, now) -> Vec<f64>`(長さ 168、JST 曜日0=日×時0..23 の平均 KB/時)。連続サンプルの差分を、またぐ時間で各マスに配分。使い放題区間は除外。`core/src/lib.rs` に `usage_heatmap() -> Vec<f64>`(mock では `seed_mock` のデータから)。`model` に必要なら薄い型。
**変更(Swift)**: `ios/PovoX/Views/Home/HeatmapView.swift`。7×24 のグリッド、色は dataviz の順次色。
**テスト**: `tests.rs` に、既知のサンプル列→期待するマスの値。
**受け入れ**: モックでヒートマップが出る。空のとき(データ不足)は案内。スクショ。

### A1. 残量予測カレンダー(今月いつ無くなるか)
**目的**: 枯渇予定日をカレンダーで。
**変更(Swift のみ)**: `ios/PovoX/Views/Home/ForecastCalendarView.swift`。`insights.hoursLeft`(または `kbPerHour` と残量)から JST の枯渇日時を出し、当月カレンダーにその日を赤く。使い放題中・減っていないときは「当分なくなりません」。
**テスト**: 枯渇日計算の純関数テスト。
**受け入れ**: カレンダーに枯渇予定日。予測不能時は素直に表示。

### C2. 購入履歴の分析(何に一番使ったか)
**目的**: 買ったトッピングを商品・月で集計。
**変更(Swift)**: `MoneyView.swift` にセクション追加。`store` に `purchase_history`(`[Purchase]`)がある。商品名でグルーピングして回数・概算金額、月別の合計。
**テスト**: 集計の純関数テスト。
**受け入れ**: 「使い放題24時間 ×3、データ1GB ×2…」のような集計。モックでスクショ。

---

## Wave 6 — 賢い検知(エンジンに状態を持たせる)

### A4. 急減アラート(直近の異常な減り)
**目的**: 普段よりずっと速く減っているとき気づく。
**変更(エンジン)**: `history.rs`/`insights` に「直近1時間の減り」と「基準(7日平均)」を足し、`UsageInsights` に `recent_kb_per_hour: Option<f64>` を追加。`lib.rs` に `pace_alert() -> Option<String>`(基準の N 倍を超えたら文言)。しきい値は設定に(`Settings` に `pace_alert_ratio`、既定3.0、0 で無効)。
**変更(Swift)**: 自動チェックの中で `pace_alert` を見て通知(`notifyErrors` とは別の控えめな通知)。ホームに帯。
**テスト**: `tests.rs` で、急に減るサンプル列→アラート、通常→無し。
**受け入れ**: モックで急減時に通知。設定でしきい値変更・無効化。

### A5. 使い放題の費用対効果(元が取れたか)
**目的**: 買った使い放題で、実際どれだけ使えたか。
**変更(エンジン)**: 使い放題の「エピソード」を記録する(開始・終了・その間に使ったみなし GB)。`fetch_snapshot` で使い放題の开始/終了を検出し、`PersistState` に `Vec<UnlimitedEpisode>` を保存(上限 50、壊れても他を守る従来方式)。価格は購入時の `ledger`/`catalog` から推定。`lib.rs` に `unlimited_episodes(limit) -> Vec<UnlimitedEpisode>`。
**変更(Swift)**: 履歴の詳細に「この使い放題で約 X GB(1円あたり Y MB 相当)」。
**テスト**: `tests.rs` で、使い放題 ON→使用→OFF のサンプルから GB とエピソードができる。
**受け入れ**: モックでエピソードと費用対効果が出る。

### D3. 使い放題の自動継ぎ(第一級トグル)
**目的**: 使い放題が切れる直前に、コード/購入で途切れず継ぐ。
**変更**: 「使い放題の見張り」レシピの考えを設定の第一級トグルに。`AppSettings` に `autoExtendUnlimited`(既定オフ)と残り分数のしきい値。オンのとき、該当のルールを自動チェックに差し込む(安全装置は従来どおり・既定は通知で確認)。
**テスト**: 使い放題の残りが少ないときに計画が出ることをエンジン/評価テストで。
**受け入れ**: 設定でオン/オフ。オンでシミュレーターに反映。

---

## Wave 7 — ウィジェットの拡充

### B2. ロック画面ウィジェット＆スタンバイ
**目的**: ロック画面と StandBy に残量。
**変更**: `ios/PovoXWidget/PovoXWidget.swift` に accessory ファミリー(`accessoryCircular`/`accessoryRectangular`/`accessoryInline`)。データは App Group の `SharedSnapshot`(既存)。
**制約**: LiveContainer/Mac では動かない。`Runtime.widgetsAvailable` 前提。
**テスト**: ウィジェットのプレビュー/ギャラリー(`WidgetGalleryView`)に追加。
**受け入れ**: 円/角/インラインが出る。スクショ。

### B3. ウィジェットの種類・サイズ追加
**目的**: 予測やヒートマップの小型版をホーム画面に。
**変更**: `PovoXWidget.swift` に新しい `Widget`(予測ミニ、ペースミニ)。`SharedSnapshot` に必要な値(予測時間など)を足す(既に `hoursLeft` あり)。
**テスト**: ギャラリーに追加・スクショ。
**受け入れ**: 複数のウィジェットが選べる。

---

## Wave 8 — 自動化の幅

### D1. モード切替(節約/旅行/通常)
**目的**: 複数のルールを保存して、1タップ/ショートカットで切り替え。
**変更**: `AppSettings` に「名前つきルールの集まり」と「今のモード」。ルール画面にモードの切替 UI。`ios/PovoX/Automation/Intents.swift` に `SetModeIntent`(App Intent、`AppEnum` でモード選択)。
**仕様**: モードは数個の既定(節約=買わない寄り/旅行=厚め/通常=標準)＋ユーザー追加。切替で `ruleSource` が変わる。ショートカットから変えられる。
**テスト**: Intent のテスト(既存 `IntentTests` に倣う)。切替でルールが変わること。
**受け入れ**: モードを作って切替。ショートカットでも。スクショ。

### D2. 定期チャージ(スケジュール)
**目的**: 「毎晩23時」「通勤時間」など、時間帯の自動チェックを第一級に。
**変更**: きっかけの画面(`TriggersView`)にスケジュール UI。実体はローカル通知/BG の予約＋ショートカット案内(iOS の制約で“確実”はショートカット)。`BackgroundScheduler` に希望時刻の予約を足す。
**制約**: 背面実行は iOS 依存。確実版はショートカットのオートメーションへ誘導(既存の仕組み)。
**テスト**: 予約ロジックの単体テスト。
**受け入れ**: 時刻を決めて予約。次回予定が見える。

---

## Wave 9 — 大物(最後)

### B1. Live Activity(使い放題カウントダウン/残量)
**目的**: 使い放題の残り時間・残量をロック画面と Dynamic Island に常時。
**変更**: `ios/PovoXWidget` に ActivityKit の `ActivityConfiguration`。アプリ側で使い放題開始時に `Activity.request`、`fetch_snapshot` 更新時に `update`、終了で `end`。`Info.plist` に `NSSupportsLiveActivities`。
**制約**: 無料 Apple ID でもローカル更新は可。LiveContainer/Mac 不可(`Runtime` で無効)。プッシュ更新はしない。
**テスト**: 開始/更新/終了の呼び出しをモックで(UI は実機確認が中心)。
**受け入れ**: 使い放題中に島とロック画面にカウントダウン。

### C3. 請求 PDF 一括保存
**目的**: 過去の請求 PDF をまとめて保存・共有。
**変更**: `BillsView`(`AccountViews.swift`)に「全部保存」。`bill_pdf` を順に取得(1本ずつ・レート制限内)、まとめて共有(複数ファイル or ZIP)。
**制約**: PDF はパスワード付き(生年月日 YYYY-MM-DD)。復号はしない。
**テスト**: 複数取得のまとめロジック。モックで2件取得。
**受け入れ**: 複数 PDF をまとめて共有。

---

## 進め方

各波の頭で `TaskCreate` に機能を登録 → エンジン→Swift の順で実装 → `cargo test` → push → CI 緑を確認 → ビルド番号とともに報告。
拡張が絡む波(7・9)は、Mac/LiveContainer で非表示になることを `Runtime` で保証してから出す。
