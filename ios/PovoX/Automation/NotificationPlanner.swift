import Foundation

/// 出す通知の中身(UserNotifications に渡す前の形)。
struct PlannedNotification: Equatable {
    enum Kind: String {
        /// 実行するか聞く(ボタン付き)。
        case confirm
        case info
        case error
        /// 3Dセキュアの認証が要る。
        case threeDS
    }

    let id: String
    let kind: Kind
    let title: String
    let body: String
    let userInfo: [String: String]
}

/// 実行の記録から、出す通知を決める。
enum NotificationPlanner {
    static func plan(for record: RunRecord, notifyErrors: Bool, notifyActions: Bool, confirmTtlMin: UInt32) -> [PlannedNotification] {
        guard record.mode != .simulate else { return [] }
        var out: [PlannedNotification] = []
        if let err = record.error {
            if notifyErrors {
                out.append(PlannedNotification(id: "run-\(record.id)-error", kind: .error, title: "povoX: 自動チェックでエラー",
                                               body: err, userInfo: ["route": "activity"]))
            }
            return out
        }
        for (i, o) in record.outcomes.enumerated() {
            let nid = "run-\(record.id)-\(i)"
            switch o.status {
            case .queued:
                guard let pid = o.pendingId else { continue }
                let verb = o.kind == .buy ? "購入" : "適用"
                out.append(PlannedNotification(
                    id: "pending-\(pid)", kind: .confirm, title: "povoX: \(verb)しますか?",
                    body: "\(o.label)\n\(confirmTtlMin)分以内に「実行する」を押すと\(verb)します。",
                    userInfo: ["pending_id": pid, "route": "activity"]))
            case .notified:
                out.append(PlannedNotification(id: nid, kind: .info, title: o.title ?? "povoX", body: o.body ?? "", userInfo: ["route": "home"]))
            case .done:
                if let url = o.challengeUrl {
                    out.append(PlannedNotification(id: nid, kind: .threeDS, title: "povoX: 3Dセキュアの認証が必要です",
                                                   body: "\(o.label)\nタップして認証してください(まだ課金されていません)。",
                                                   userInfo: ["challenge_url": url, "label": o.label, "route": "home"]))
                } else if notifyActions {
                    let verb = o.kind == .buy ? "購入しました" : "コードを適用しました"
                    out.append(PlannedNotification(id: nid, kind: .info, title: "povoX: \(verb)", body: "\(o.label)\n\(o.message)", userInfo: ["route": "activity"]))
                }
            case .failed:
                out.append(PlannedNotification(id: nid, kind: .error, title: "povoX: 失敗しました", body: "\(o.label)\n\(o.message)", userInfo: ["route": "activity"]))
            default:
                continue
            }
        }
        return out
    }

    /// 通知の「実行する」を押した結果。
    static func plan(forConfirmed o: ActionOutcome) -> PlannedNotification {
        let id = "confirmed-\(o.pendingId ?? UUID().uuidString)"
        if let url = o.challengeUrl {
            return PlannedNotification(id: id, kind: .threeDS, title: "povoX: 3Dセキュアの認証が必要です",
                                       body: "\(o.label)\nタップして認証してください。", userInfo: ["challenge_url": url, "label": o.label, "route": "home"])
        }
        switch o.status {
        case .done:
            return PlannedNotification(id: id, kind: .info, title: o.kind == .buy ? "povoX: 購入しました" : "povoX: コードを適用しました",
                                       body: "\(o.label)\n\(o.message)", userInfo: ["route": "home"])
        case .failed:
            return PlannedNotification(id: id, kind: .error, title: "povoX: 失敗しました", body: "\(o.label)\n\(o.message)", userInfo: ["route": "activity"])
        default:
            return PlannedNotification(id: id, kind: .info, title: "povoX: 実行しませんでした", body: "\(o.label)\n\(o.message)", userInfo: ["route": "activity"])
        }
    }
}
