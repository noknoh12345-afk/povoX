import SwiftUI
import UIKit

/// 検証用の書き出しを作る(端末の中で JSON ファイルにする。送るかは利用者が共有シートで決める)。
enum ExportBuilder {
    struct Options {
        var calendar = true
        var redact = false
        var purchases = true
    }

    static func build(services: AppServices, options: Options, now: Date = Date()) async -> URL? {
        let c = services.client
        let include = options.purchases
        let engineJSON = await c.value { $0.exportJson(includePurchases: include) }
        var root: [String: Any] = [:]
        root["format"] = "povox-bundle/1"
        root["exportedMs"] = Int64(now.timeIntervalSince1970 * 1000)
        root["engine"] = (try? JSONSerialization.jsonObject(with: Data(engineJSON.utf8))) ?? engineJSON
        let info = Bundle.main.infoDictionary ?? [:]
        root["app"] = [
            "version": info["CFBundleShortVersionString"] as? String ?? "",
            "build": info["CFBundleVersion"] as? String ?? "",
            "runtime": Runtime.label,
            "backgroundTasks": Runtime.backgroundTasksAvailable,
            "backgroundEnabled": services.settings.backgroundEnabled,
            "locationEnabled": services.settings.locationEnabled,
            "ruleEnabled": services.settings.ruleEnabled,
            "intensity": services.settings.usageIntensity,
        ] as [String: Any]
        root["device"] = await MainActor.run {
            ["model": UIDevice.current.model, "system": UIDevice.current.systemVersion,
             "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled] as [String: Any]
        }
        if options.calendar {
            let cal = services.calendar
            root["calendar"] = ["authorized": cal.authorized, "redacted": options.redact, "daysBack": 90, "daysAhead": 2,
                                "events": cal.rawEvents(daysBack: 90, daysAhead: 2, redact: options.redact, now: now)] as [String: Any]
        }
        let events = services.wakeLog.events()
        root["wake"] = [
            "events": encode(events) ?? [Any](),
            "report7d": encode(WakeStats.report(events, now: now, days: 7)) ?? NSNull(),
        ] as [String: Any]
        root["flows"] = encode(services.flows.flows()) ?? [Any]()
        root["flowMemory"] = encode(services.flows.memory()) ?? NSNull()
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else { return nil }
        let c2 = DayPlanner.tokyo.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let name = String(format: "povox-export-%04d%02d%02d-%02d%02d.json", c2.year ?? 0, c2.month ?? 0, c2.day ?? 0, c2.hour ?? 0, c2.minute ?? 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }

    /// Codable → JSONSerialization で扱える形。
    static func encode<T: Encodable>(_ v: T) -> Any? {
        guard let d = try? JSONEncoder().encode(v) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }
}

/// 「計測と書き出し」: 第1段の数字(起こされ方・通知の遅れ・通信量)と、検証用データの書き出し。
struct ExportView: View {
    @EnvironmentObject var store: AppStore
    @State private var options = ExportBuilder.Options()
    @State private var file: URL?
    @State private var building = false
    @State private var report: WakeReport?
    @State private var days = 7.0
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                if let r = report {
                    ForEach(Array(WakeStats.lines(r).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout)
                    }
                } else {
                    ProgressView()
                }
                Picker("期間", selection: $days) {
                    Text("1日").tag(1.0)
                    Text("7日").tag(7.0)
                    Text("30日").tag(30.0)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("実際に起こされた回数と時刻")
            } footer: {
                Text("povoX が先回りできるかは、iOS がいつアプリを起こすかと、予約した通知が時刻どおり届くかで決まります。ここは推測ではなく、この iPhone で記録した数字です。通知の遅れは、通知センターに残っているものから拾います(消したものは数えられません)。")
            }
            .accessibilityIdentifier("export.report")

            Section {
                Toggle("予定を含める(過去90日)", isOn: $options.calendar)
                if options.calendar {
                    Toggle("予定のタイトル・場所を伏せる", isOn: $options.redact)
                }
                Toggle("povo の購入履歴を含める(通信1回)", isOn: $options.purchases)
                Button {
                    Task { await build() }
                } label: {
                    HStack {
                        Label("書き出すファイルを作る", systemImage: "doc.badge.arrow.up")
                        Spacer()
                        if building { ProgressView() }
                    }
                }
                .disabled(building)
                .accessibilityIdentifier("export.build")
                if let file {
                    ShareLink(item: file) {
                        Label("共有・保存(\(file.lastPathComponent))", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("export.share")
                }
            } header: {
                Text("検証用の書き出し")
            } footer: {
                Text("残量の記録(最長120日)・実行の記録・購入の台帳・コード(伏せ字)・設定・オートメーション・上の計測・予定を1つの JSON にします。ログイン情報とコードの全文は入れません。ファイルは端末の中に作るだけで、送るかどうかは共有シートで決めます。伏せると、予定の種類の見分け(旅行・ライブなど)の検証には使えません。")
            }

            Section {
                Button("計測の記録を消す", role: .destructive) { confirmClear = true }
            }
        }
        .navigationTitle("計測と書き出し")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: days) { refresh() }
        .confirmationDialog("計測の記録を消しますか?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("消す", role: .destructive) {
                store.services.wakeLog.clear()
                refresh()
            }
        }
    }

    private func refresh() {
        report = WakeStats.report(store.services.wakeLog.events(), now: Date(), days: days)
    }

    private func build() async {
        building = true
        file = await ExportBuilder.build(services: store.services, options: options)
        building = false
        if file == nil { store.toast = "ファイルを作れませんでした" }
    }
}
