import Foundation
import SwiftUI

/// 画面の状態。povo への操作は Core(Rust)をバックグラウンドのスレッドで呼ぶ。
@MainActor
final class AppModel: ObservableObject {
    @Published var status: EngineStatus?
    @Published var snapshot: Snapshot?
    @Published var catalog: Catalog?
    @Published var codes: [CodeItem] = []
    @Published var logs: [LogItem] = []
    @Published var ledger: [LedgerItem] = []
    @Published var busy = false
    @Published var error: CoreError?
    @Published var toast: String?
    @Published var lastReport: String? = Automation.lastReportText
    @Published var challenge: ChallengePage?

    private var foregroundTimer: Timer?

    init() {
        NotificationCenter.default.addObserver(forName: .povoxDidRun, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.lastReport = Automation.lastReportText
                await self.reloadLocal()
            }
        }
    }

    /// Core を別スレッドで呼ぶ。
    nonisolated func core<T: Decodable>(_ op: String, _ args: [String: Any] = [:], as type: T.Type) async -> Result<T, CoreError> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Core.shared.decode(op, args, as: type))
            }
        }
    }

    nonisolated func coreRaw(_ op: String, _ args: [String: Any] = [:]) async -> Result<Any, CoreError> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Core.shared.call(op, args))
            }
        }
    }

    // MARK: - 読み込み

    /// 通信なしで分かるものを読み直す。
    func reloadLocal() async {
        if case .success(let s) = await core("status", as: EngineStatus.self) { status = s }
        if case .success(let s) = await core("cached_snapshot", as: Snapshot?.self) { snapshot = s }
        if case .success(let c) = await core("codes", as: [CodeItem].self) { codes = c }
        if case .success(let l) = await core("logs", ["limit": 200], as: [LogItem].self) { logs = l }
        if case .success(let l) = await core("ledger", as: [LedgerItem].self) { ledger = l }
    }

    func refresh(force: Bool = true) async {
        guard status?.loggedIn == true else { return }
        busy = true
        defer { busy = false }
        switch await core("snapshot", ["force": force], as: Snapshot.self) {
        case .success(let s): snapshot = s
        case .failure(let e): error = e
        }
        await reloadLocal()
    }

    func loadCatalog(force: Bool) async {
        busy = true
        defer { busy = false }
        switch await core("catalog", ["force": force], as: Catalog.self) {
        case .success(let c): catalog = c
        case .failure(let e): error = e
        }
        await reloadLocal()
    }

    // MARK: - ログイン

    func loginStart(email: String, phone: String) async -> Bool {
        busy = true
        defer { busy = false }
        var args: [String: Any] = [:]
        if !email.trimmingCharacters(in: .whitespaces).isEmpty { args["email"] = email }
        if !phone.trimmingCharacters(in: .whitespaces).isEmpty { args["phone"] = phone }
        let r = await core("login_start", args, as: LoginStep.self)
        await reloadLocal()
        switch r {
        case .success(let s):
            toast = "\(s.sent ?? "コード")を送りました"
            return true
        case .failure(let e):
            error = e
            return false
        }
    }

    func loginResend() async {
        busy = true
        defer { busy = false }
        switch await core("login_resend", as: LoginStep.self) {
        case .success(let s): toast = "\(s.sent ?? "コード")を送り直しました"
        case .failure(let e): error = e
        }
        await reloadLocal()
    }

    func loginOTP(_ code: String) async {
        busy = true
        defer { busy = false }
        switch await core("login_otp", ["code": code], as: LoginStep.self) {
        case .success(let s):
            if s.done == true {
                toast = "ログインしました"
                await reloadLocal()
                await refresh(force: true)
                return
            }
            toast = "続けて\(s.sent ?? "次のコード")を入力してください"
        case .failure(let e):
            error = e
        }
        await reloadLocal()
    }

    func loginCancel() async {
        _ = await coreRaw("login_cancel")
        await reloadLocal()
    }

    func logout() async {
        _ = await coreRaw("logout")
        snapshot = nil
        catalog = nil
        await reloadLocal()
    }

    func unhalt() async {
        _ = await coreRaw("unhalt")
        await reloadLocal()
    }

    func setMock(_ on: Bool) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                Core.shared.setMock(on)
                cont.resume()
            }
        }
        snapshot = nil
        catalog = nil
        await reloadLocal()
    }

    // MARK: - 購入・コード

    func order(_ p: Product, confirm: String) async {
        busy = true
        defer { busy = false }
        switch await core("order", ["sku": p.sku, "confirm": confirm], as: OrderResult.self) {
        case .success(let r):
            if r.needs3ds, let url = r.challengeUrl.flatMap(URL.init(string:)) {
                challenge = ChallengePage(url: url, productName: p.name)
            } else {
                toast = "\(p.name) を注文しました。購入履歴と残量で反映を確かめてください。"
            }
        case .failure(let e):
            error = e
        }
        await reloadLocal()
    }

    func applyCode(id: String? = nil, raw: String? = nil, confirm: String) async {
        busy = true
        defer { busy = false }
        var args: [String: Any] = ["confirm": confirm]
        if let id { args["id"] = id }
        if let raw { args["code"] = raw }
        switch await core("apply_code", args, as: CodeApplyResult.self) {
        case .success(let r):
            let m = r.result
            let text = [m?.title, m?.message].compactMap { $0 }.joined(separator: "\n")
            toast = (r.valid == true ? "適用しました\n" : "受け付けられませんでした\n") + text
        case .failure(let e):
            error = e
        }
        await reloadLocal()
    }

    func addCodes(_ text: String) async -> CodesAddResult? {
        let r = await core("codes_add", ["text": text], as: CodesAddResult.self)
        await reloadLocal()
        switch r {
        case .success(let x): return x
        case .failure(let e):
            error = e
            return nil
        }
    }

    func editCode(_ op: String, id: String, tag: String? = nil, note: String? = nil) async {
        var args: [String: Any] = ["id": id]
        if let tag { args["tag"] = tag }
        if let note { args["note"] = note }
        if case .failure(let e) = await coreRaw(op, args) { error = e }
        await reloadLocal()
    }

    func saveSettings(_ s: EngineSettings) async {
        let args: [String: Any] = [
            "dry_run": s.dryRun, "monthly_cap_yen": s.monthlyCapYen,
            "max_auto_orders_per_day": s.maxAutoOrdersPerDay,
            "auto_order_gap_min": s.autoOrderGapMin, "auto_codes": s.autoCodes,
        ]
        if case .failure(let e) = await coreRaw("settings_set", args) { error = e }
        await reloadLocal()
    }

    func clearLogs() async {
        _ = await coreRaw("logs_clear")
        await reloadLocal()
    }

    // MARK: - 自動チェック

    func runNow(test: Bool) async -> RunReport {
        busy = true
        defer { busy = false }
        let report = await Automation.shared.run(trigger: test ? "test" : "manual", forceDryRun: test)
        lastReport = Automation.lastReportText
        await reloadLocal()
        return report
    }

    /// アプリを開いている間の自動チェック。
    func startForegroundTimer() {
        foregroundTimer?.invalidate()
        guard Automation.foregroundEnabled else { return }
        let interval = TimeInterval(Automation.intervalMinutes * 60)
        foregroundTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task {
                guard case .success(let st) = Core.shared.decode("status", as: EngineStatus.self), st.loggedIn else { return }
                _ = await Automation.shared.run(trigger: "foreground")
            }
        }
        // 開いた直前に長く止まっていたら、すぐ1回動かす。
        if let last = Automation.lastRun, Date().timeIntervalSince(last) < interval { return }
        Task {
            guard status?.loggedIn == true else { return }
            _ = await Automation.shared.run(trigger: "foreground")
        }
    }

    func stopForegroundTimer() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }
}

struct ChallengePage: Identifiable {
    let id = UUID()
    let url: URL
    let productName: String
}
