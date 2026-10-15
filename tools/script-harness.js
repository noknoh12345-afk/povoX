// 開発用: アプリのスクリプト実行(ScriptRunner.swift の prelude + 既定スクリプト)を
// Node 上で、本物の Rust エンジン(モック)につないで動かす。
//   node tools/script-harness.js <stateDir> [scriptFile] [ctxJSON] [forceDry]
const fs = require("fs"), vm = require("vm"), path = require("path"), cp = require("child_process");
const root = path.join(__dirname, "..");
function swiftRaw(file, name) {
  const s = fs.readFileSync(path.join(root, file), "utf8");
  const start = s.indexOf(`static let ${name} = #"""`);
  const body = s.slice(s.indexOf("\n", start) + 1, s.indexOf('"""#', start));
  return body.split("\n").map(l => l.startsWith("    ") ? l.slice(4) : l).join("\n").replace(/\n\s*$/, "");
}
const prelude = swiftRaw("ios/PovoX/Automation/ScriptRunner.swift", "prelude");
const [dir, scriptFile, ctxJSON, forceDry] = process.argv.slice(2);
const script = scriptFile && scriptFile !== "-" ? fs.readFileSync(scriptFile, "utf8") : swiftRaw("ios/PovoX/Automation/DefaultScript.swift", "text");
const cli = path.join(root, "core/target/debug/examples/cli");
const state = {};
const sandbox = {
  __native_call(op, args) {
    const req = JSON.parse(args); req.op = op;
    return cp.execFileSync(cli, [dir, JSON.stringify(req)]).toString().trim();
  },
  __native_force_dry: () => forceDry === "1",
  __native_log: m => console.log("  log:", m),
  __native_notify: (t, b) => console.log("  notify:", t, "|", b),
  __native_state_get: k => state[k] ?? "",
  __native_state_set: (k, v) => { state[k] = v; },
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(prelude, sandbox);
vm.runInContext(script, sandbox);
const run = vm.runInContext("typeof run === 'function' ? run : undefined", sandbox);
const ctx = Object.assign({ trigger: "manual", battery: { level: 80, charging: false, full: false, lowPower: false },
  network: "cellular", now: { hour: 12, minute: 0, weekday: 4, date: "2026-10-15", ms: Date.now() }, lastRun: null, dryRun: true, mock: true, args: {} },
  ctxJSON ? JSON.parse(ctxJSON) : {});
console.log("result:", run(ctx));
