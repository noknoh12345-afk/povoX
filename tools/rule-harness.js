// 開発用: アプリと同じ rule-prelude.js とルールを Node で評価し、本物の Rust エンジン(モック)で
// 計画を実行する。iOS の JavaScriptCore の代わりに Node を使うだけで、流れはアプリと同じ:
//   ctx = engine.rule_context → decide(ctx) → engine.execute_run(計画)
//
//   node tools/rule-harness.js --dir /tmp/st [--rule ファイル|テンプレート名] [--mode live|dry|simulate]
//        [--ctx '{"battery":{"level":10}}'] [--sim '{"left_kb":100000,"unlimited":false}'] [--scenario low]
const fs = require("fs"), vm = require("vm"), path = require("path"), cp = require("child_process");
const root = path.join(__dirname, "..");
const argv = process.argv.slice(2);
const opt = (k, d) => { const i = argv.indexOf("--" + k); return i >= 0 ? argv[i + 1] : d; };
const dir = opt("dir");
if (!dir) { console.error("--dir が必要です"); process.exit(2); }
const mode = opt("mode", "live");
const scenario = opt("scenario", "");
const ruleArg = opt("rule", "standard");
const rulePath = fs.existsSync(ruleArg) ? ruleArg : path.join(root, "ios/PovoX/Resources/templates", ruleArg + ".js");
const prelude = fs.readFileSync(path.join(root, "ios/PovoX/Resources/rule-prelude.js"), "utf8");
const rule = fs.readFileSync(rulePath, "utf8");
const cli = path.join(root, "core/target/debug/examples/cli");

function dev(op, args) {
  const out = cp.execFileSync(cli, [dir, op, JSON.stringify(args ?? null)], { env: { ...process.env, MOCK_SCENARIO: scenario } }).toString().trim();
  return JSON.parse(out);
}

const sim = opt("sim") ? JSON.parse(opt("sim")) : null;
const base = dev("rule_context", { mode, sim });
if (!base.ok) { console.log("rule_context failed:", base.error.message); process.exit(1); }
const device = Object.assign({
  trigger: "harness",
  battery: { level: 80, charging: false, full: false, lowPower: false },
  network: "cellular",
  now: { hour: 12, minute: 0, weekday: 4, date: "2026-10-15", ms: Date.now() },
  args: {},
}, opt("ctx") ? JSON.parse(opt("ctx")) : {});
const ctx = Object.assign({}, base.result, device);

const logs = [];
const state = {};
const sandbox = {
  __native_call(op, args) { const r = dev("script", { op, args: JSON.parse(args) }); return JSON.stringify(r); },
  __native_log: (m) => logs.push(m),
  __native_state_get: (k) => state[k] ?? "",
  __native_state_set: (k, v) => { state[k] = v; },
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
let planJSON = null, error = null;
try {
  vm.runInContext(prelude, sandbox, { filename: "rule-prelude.js" });
  vm.runInContext(rule, sandbox, { filename: path.basename(rulePath) });
  planJSON = vm.runInContext("__povox_run", sandbox)(JSON.stringify(ctx));
} catch (e) {
  error = (e && e.message) || String(e);
}
const input = {
  trigger: device.trigger, mode, battery_level: device.battery.level ?? null, charging: !!device.battery.charging,
  network: device.network, plan_json: planJSON, error, script_logs: logs, sim,
};
const res = dev("execute_run", input);
if (!res.ok) { console.log("execute_run failed:", res.error.message); process.exit(1); }
const r = res.result;
console.log(`plan:    ${planJSON ?? "(なし)"}`);
if (error) console.log(`error:   ${error}`);
for (const l of logs) console.log(`log:     ${l}`);
console.log(`summary: ${r.summary}`);
for (const o of r.outcomes) console.log(`  - [${o.kind}/${o.status}] ${o.label}: ${o.message}${o.pending_id ? " (pending " + o.pending_id + ")" : ""}`);
if (opt("json")) console.log(JSON.stringify(r));
