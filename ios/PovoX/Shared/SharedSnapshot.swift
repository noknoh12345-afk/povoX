import Foundation

/// アプリからウィジェットへ渡す残量(App Group の共有フォルダの JSON)。
/// ウィジェットは povo へ通信しない。アプリが残量を取るたびにここを書き換える。
struct SharedSnapshot: Codable, Equatable {
    var updatedAt: Date
    var leftKB: Double?
    var planKB: Double?
    var unlimitedActive: Bool
    var unlimitedUntil: Date?
    var hoursLeft: Double?
    var pendingCount: Int
    var mock: Bool
    var lastSummary: String?

    static let appGroup = "group.jp.povox.app"
    private static let fileName = "widget-snapshot.json"

    static var containerURL: URL? {
        #if os(Linux)
        return nil
        #else
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        #endif
    }

    static func url(in dir: URL? = containerURL) -> URL? {
        dir?.appendingPathComponent(fileName)
    }

    static func load(from dir: URL? = containerURL) -> SharedSnapshot? {
        guard let u = url(in: dir), let data = try? Data(contentsOf: u) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return try? d.decode(SharedSnapshot.self, from: data)
    }

    @discardableResult
    func save(to dir: URL? = SharedSnapshot.containerURL) -> Bool {
        guard let u = SharedSnapshot.url(in: dir) else { return false }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? e.encode(self) else { return false }
        return (try? data.write(to: u, options: .atomic)) != nil
    }

    static let placeholder = SharedSnapshot(
        updatedAt: Date(), leftKB: 12.4 * 1_048_576, planKB: 20 * 1_048_576, unlimitedActive: false,
        unlimitedUntil: nil, hoursLeft: 30, pendingCount: 0, mock: true, lastSummary: nil)
}
