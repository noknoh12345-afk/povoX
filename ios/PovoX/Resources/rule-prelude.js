// povoX: ルールの下ごしらえ(アプリと、パソコン上のテストで同じものを使う)。
//
// ルールは decide(ctx) で「何をするか」を返すだけ。povo への送信は povoX の安全装置が行う。
// アプリが用意するネイティブ関数:
//   __native_call(op, argsJSON) -> 応答JSON   (読み取りとログだけ: "catalog", "log")
//   __native_log(text)
//   __native_state_get(key) -> 文字列 / __native_state_set(key, valueJSON)
"use strict";

function __call(op, args) {
  const r = JSON.parse(__native_call(op, JSON.stringify(args || {})));
  if (!r.ok) {
    const e = new Error(r.error.message);
    e.povo = r.error;
    throw e;
  }
  return r.result;
}

function __fmt(a) {
  if (typeof a === "string") return a;
  if (a instanceof Error) return a.message;
  if (a === undefined) return "undefined";
  try { return JSON.stringify(a); } catch (e) { return String(a); }
}

function log() { __native_log(Array.prototype.map.call(arguments, __fmt).join(" ")); }
if (typeof console === "undefined") { globalThis.console = { log: log, warn: log, error: log, info: log }; }
else { console.log = log; console.warn = log; console.error = log; console.info = log; }

const state = {
  get(key, fallback) {
    const v = __native_state_get(String(key));
    if (v == null || v === "") return fallback;
    try { return JSON.parse(v); } catch (e) { return fallback; }
  },
  set(key, value) { __native_state_set(String(key), JSON.stringify(value === undefined ? null : value)); },
};

// ---- 計画を作る関数 ----------------------------------------------------------------

/** 何もしない(理由はログと履歴に残る)。 */
function skip(reason) { return { type: "skip", reason: reason == null ? "" : String(reason) }; }

/** 通知を出す。 */
function notify(title, body) {
  return { type: "notify", title: title == null ? "" : String(title), body: body == null ? "" : __fmt(body) };
}

/** 手持ちのコードを1件使う。applyCode() / applyCode("1gb") / applyCode({ id }) */
function applyCode(sel) {
  if (sel && typeof sel === "object") {
    if (sel.id) return { type: "applyCode", id: String(sel.id) };
    return { type: "applyCode", tag: sel.tag == null ? null : String(sel.tag) };
  }
  return { type: "applyCode", tag: sel == null ? null : String(sel) };
}

/** トッピングを買う。buy(商品) / buy("SKU")。商品が無ければ何もしない。 */
function buy(product) {
  if (product == null) return skip("条件に合う商品がありません");
  const sku = typeof product === "string" ? product : product.sku;
  if (!sku) return skip("条件に合う商品がありません");
  return { type: "buy", sku: String(sku) };
}

function __node(x) {
  if (x == null) return skip("");
  if (typeof x === "string") return skip(x);
  if (Array.isArray(x)) return all.apply(null, x);
  if (typeof x === "object" && typeof x.type === "string") return x;
  return skip(String(x));
}

/** 上から順に試し、最初にできたものだけ行う。 */
function firstOf() { return { type: "firstOf", items: Array.prototype.slice.call(arguments).flat().map(__node) }; }

/** 全部行う(ただし購入・コードは1回の自動チェックで1つまで)。 */
function all() { return { type: "all", items: Array.prototype.slice.call(arguments).flat().map(__node) }; }

/** 一覧から条件に合う最安の商品(3Dセキュアが要るもの・価格不明は除く)。 */
function cheapest(list, predicate) {
  const xs = (list || []).filter(p => p && !p.requires3ds && p.price != null && (!predicate || predicate(p)));
  xs.sort((a, b) => a.price - b.price);
  return xs.length ? xs[0] : null;
}

// ---- アプリから呼ばれる入口 ------------------------------------------------------------

function __povox_run(ctxJSON) {
  const ctx = JSON.parse(ctxJSON);
  let catalogCache = null;
  ctx.catalog = function (opts) {
    if (catalogCache === null || (opts && opts.force)) {
      try {
        catalogCache = __call("catalog", { mode: ctx.mode });
      } catch (e) {
        // 一覧を読めなくてもルールは止めない(通知などの次の手に進めるように)
        log("トッピング一覧を読めませんでした: " + e.message);
        catalogCache = [];
      }
    }
    return catalogCache;
  };
  ctx.state = state;
  if (typeof decide !== "function") throw new Error("ルールに function decide(ctx) がありません");
  return JSON.stringify(__node(decide(ctx)));
}

function __povox_check() {
  if (typeof decide !== "function") throw new Error("ルールに function decide(ctx) がありません");
  return "ok";
}
