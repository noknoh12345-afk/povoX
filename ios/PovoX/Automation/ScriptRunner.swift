import Foundation
import JavaScriptCore

/// 1回分の実行結果。
struct RunReport {
    var ok: Bool
    var summary: String
    var lines: [String]
    var startedAt: Date
    var trigger: String
}

/// 利用者のスクリプト(JavaScript)を JavaScriptCore で動かす。
/// スクリプトから povo への操作は、すべて Rust のエンジンの安全装置を通る。
enum ScriptRunner {
    /// スクリプトに渡す `povo` などの API。ネイティブ側は文字列の受け渡しだけにして、
    /// 使いやすい形への変換はここ(JS)で行う。
    static let prelude = #"""
    "use strict";
    const __FORCE_DRY = __native_force_dry();
    function __call(op, args) {
      const a = Object.assign({}, args || {});
      if (__FORCE_DRY && (op === "order" || op === "apply_code")) a.dry_run = true;
      return JSON.parse(__native_call(op, JSON.stringify(a)));
    }
    function __ok(op, args) {
      const r = __call(op, args);
      if (!r.ok) { const e = new Error(r.error.message); e.povo = r.error; throw e; }
      return r.result;
    }
    const __KB_GB = 1024 * 1024;
    function __snap(s) {
      const buckets = ((s.usage && s.usage.buckets) || []).map(b => ({
        key: b.key, label: b.label,
        leftGB: b.left_kb / __KB_GB, usedGB: b.used_kb / __KB_GB,
        planGB: b.plan_kb == null ? null : b.plan_kb / __KB_GB,
      }));
      return {
        leftGB: s.left_kb == null ? null : s.left_kb / __KB_GB,
        leftMB: s.left_kb == null ? null : s.left_kb / 1024,
        buckets: buckets,
        toppings: s.toppings || [],
        unlimitedActive: s.unlimited_active,
        unlimited: s.unlimited || null,
        fetchedAt: new Date(s.fetched_ms),
        cached: !!s.cached,
      };
    }
    function __product(p) {
      return { sku: p.sku, name: p.name, price: p.price_yen, priceText: p.price,
               validity: p.validity, section: p.section, requires3ds: !!p.requires_3ds };
    }
    const povo = {
      usage(opts) { return __snap(__ok("snapshot", { force: !!(opts && opts.force) })); },
      catalog(opts) { return __ok("catalog", { force: !!(opts && opts.force) }).products.map(__product); },
      find(pattern, opts) {
        const isRe = pattern instanceof RegExp;
        const list = povo.catalog(opts).filter(p => isRe
          ? (pattern.test(p.name) || pattern.test(p.sku))
          : (p.name.indexOf(String(pattern)) >= 0 || p.sku === pattern));
        return list.sort((a, b) => (a.price == null ? 1e9 : a.price) - (b.price == null ? 1e9 : b.price));
      },
      buy(target) {
        const sku = typeof target === "string" ? target : (target && target.sku);
        if (!sku) return { ok: false, dryRun: false, needs3ds: false, message: "商品が指定されていません" };
        const r = __call("order", { sku: sku, auto: true });
        if (!r.ok) return { ok: false, dryRun: false, needs3ds: false, message: r.error.message, error: r.error };
        const x = r.result;
        const name = (x.product && x.product.name) || sku;
        return { ok: true, dryRun: !!x.dry_run, needs3ds: !!x.needs_3ds,
                 message: x.dry_run ? ("(試運転)" + name + " を購入するところでした")
                        : x.needs_3ds ? (name + " は3Dセキュアの認証待ちです。アプリを開いてください")
                        : (name + " を注文しました") };
      },
      codes(tag) {
        return __ok("codes")
          .filter(c => c.status === "pending" && (tag == null || c.tag.toLowerCase() === String(tag).toLowerCase()))
          .map(c => ({ id: c.id, tag: c.tag, note: c.note, masked: c.masked }));
      },
      applyCode(tag) {
        const args = { auto: true };
        if (tag && typeof tag === "object" && tag.id) args.id = tag.id;
        else if (tag != null) args.tag = String(tag);
        const r = __call("apply_code", args);
        if (!r.ok) return { ok: false, dryRun: false, valid: false, message: r.error.message, error: r.error };
        const x = r.result;
        if (x.dry_run) return { ok: true, dryRun: true, valid: null, message: "(試運転)コード " + x.masked + " を適用するところでした" };
        const m = x.result || {};
        const text = [m.title, m.message].filter(Boolean).join(" ");
        return { ok: true, dryRun: false, valid: !!x.valid, message: (x.valid ? "適用しました: " : "受け付けられませんでした: ") + text };
      },
      budget() {
        const b = __ok("budget");
        return { capYen: b.cap_yen, spentYen: b.auto_spent_yen, remainingYen: b.remaining_yen,
                 todayCount: b.auto_today, maxPerDay: b.max_auto_per_day };
      },
      get dryRun() { return __FORCE_DRY || !!__ok("settings").dry_run; },
    };
    function __fmt(a) {
      if (typeof a === "string") return a;
      if (a instanceof Error) return a.message;
      try { return JSON.stringify(a); } catch (e) { return String(a); }
    }
    function log() { __native_log(Array.prototype.map.call(arguments, __fmt).join(" ")); }
    if (typeof console === "undefined") { globalThis.console = { log: log, warn: log, error: log }; }
    else { console.log = log; console.warn = log; console.error = log; }
    function notify(title, body) { __native_notify(String(title), body == null ? "" : __fmt(body)); }
    const state = {
      get(k, d) { const v = __native_state_get(String(k)); return (v == null || v === "") ? d : JSON.parse(v); },
      set(k, v) { __native_state_set(String(k), JSON.stringify(v === undefined ? null : v)); },
    };
    """#

    /// スクリプトを1回実行する。呼ぶのは画面のスレッド以外から。
    static func run(script: String, context: [String: Any], forceDryRun: Bool, trigger: String,
                    notify: @escaping (String, String) -> Void) -> RunReport {
        let started = Date()
        var lines: [String] = []
        let linesLock = NSLock()
        func addLine(_ s: String) {
            linesLock.lock(); lines.append(s); linesLock.unlock()
        }

        guard let ctx = JSContext() else {
            return RunReport(ok: false, summary: "JavaScript を起動できませんでした", lines: [], startedAt: started, trigger: trigger)
        }
        var exception: String?
        ctx.exceptionHandler = { _, value in
            let msg = value?.objectForKeyedSubscript("message")?.toString() ?? value?.toString() ?? "不明なエラー"
            let line = value?.objectForKeyedSubscript("line")?.toString()
            exception = line.map { "\(msg)(\($0)行目)" } ?? msg
        }

        let call: @convention(block) (String, String) -> String = { op, args in
            Core.shared.callRaw(op: op, argsJSON: args)
        }
        let forceDry: @convention(block) () -> Bool = { forceDryRun }
        let log: @convention(block) (String) -> Void = { msg in
            addLine(msg)
            _ = Core.shared.call("log", ["level": "info", "message": "[スクリプト] " + msg])
        }
        let notifyBlock: @convention(block) (String, String) -> Void = { title, body in
            addLine("通知: \(title) \(body)")
            notify(title, body)
        }
        let stateGet: @convention(block) (String) -> String = { key in
            ScriptState.get(key) ?? ""
        }
        let stateSet: @convention(block) (String, String) -> Void = { key, value in
            ScriptState.set(key, value)
        }
        ctx.setObject(call, forKeyedSubscript: "__native_call" as NSString)
        ctx.setObject(forceDry, forKeyedSubscript: "__native_force_dry" as NSString)
        ctx.setObject(log, forKeyedSubscript: "__native_log" as NSString)
        ctx.setObject(notifyBlock, forKeyedSubscript: "__native_notify" as NSString)
        ctx.setObject(stateGet, forKeyedSubscript: "__native_state_get" as NSString)
        ctx.setObject(stateSet, forKeyedSubscript: "__native_state_set" as NSString)

        ctx.evaluateScript(prelude)
        if let e = exception {
            return RunReport(ok: false, summary: "内部スクリプトのエラー: \(e)", lines: lines, startedAt: started, trigger: trigger)
        }
        ctx.evaluateScript(script)
        if let e = exception {
            return finish(ok: false, summary: "スクリプトの読み込みエラー: \(e)", lines: lines, started: started, trigger: trigger)
        }
        // function run(ctx) {…} でも const run = (ctx) => {…} でも見つける。
        guard let runFn = ctx.evaluateScript("typeof run === 'function' ? run : undefined"), runFn.isObject else {
            return finish(ok: false, summary: "スクリプトに function run(ctx) がありません", lines: lines, started: started, trigger: trigger)
        }
        let result = runFn.call(withArguments: [context])
        if let e = exception {
            return finish(ok: false, summary: "スクリプトのエラー: \(e)", lines: lines, started: started, trigger: trigger)
        }
        var summary = lines.last ?? "完了"
        if let r = result, r.isString, let s = r.toString(), !s.isEmpty {
            summary = s
        }
        return finish(ok: true, summary: summary, lines: lines, started: started, trigger: trigger)
    }

    private static func finish(ok: Bool, summary: String, lines: [String], started: Date, trigger: String) -> RunReport {
        if !ok {
            _ = Core.shared.call("log", ["level": "error", "message": "[スクリプト] " + summary])
        }
        return RunReport(ok: ok, summary: summary, lines: lines, startedAt: started, trigger: trigger)
    }
}

/// スクリプトの `state.get/set` の保存先(実行をまたいで残る小さな値)。
enum ScriptState {
    private static let key = "scriptState"
    private static let lock = NSLock()

    static func get(_ k: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[k]
    }

    static func set(_ k: String, _ v: String) {
        lock.lock(); defer { lock.unlock() }
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        d[k] = v
        UserDefaults.standard.set(d, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
