import Foundation

// パソコン上でオートメーションと今日のプランの中身を検査する(tools/flow-check.sh から)。
var failures: [String] = []
FlowLogicChecks.run { failures.append($0) }
WakeChecks.run { failures.append("計測: " + $0) }
if failures.isEmpty {
    print("flow-check: OK")
} else {
    for f in failures { print("✗ \(f)") }
    print("flow-check: \(failures.count) 件の失敗")
    exit(1)
}
