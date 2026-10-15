import Foundation

// Rust の応答(snake_case)を JSONDecoder.convertFromSnakeCase で読む。

struct EngineStatus: Decodable {
    let mock: Bool
    let loggedIn: Bool
    let identifier: String?
    let halted: String?
    let blockedUntilMs: Int64?
    let login: LoginState?
    let otpCooldownS: Int?
    let settings: EngineSettings
    let budget: Budget
    let codesPending: Int
    let snapshotMs: Int64?
}

struct LoginState: Decodable {
    let identifier: String?
    let current: String?
    let remaining: Int
}

struct EngineSettings: Decodable, Equatable {
    var dryRun: Bool
    var monthlyCapYen: Int
    var maxAutoOrdersPerDay: Int
    var autoOrderGapMin: Int
    var autoCodes: Bool
}

struct Budget: Decodable {
    let capYen: Int
    let autoSpentYen: Int
    let allSpentYen: Int
    let remainingYen: Int
    let autoToday: Int
    let maxAutoPerDay: Int
}

struct Snapshot: Decodable {
    let fetchedMs: Int64
    let usage: Usage?
    let toppings: [Topping]?
    let toppingsError: String?
    let leftKb: Double?
    let unlimitedActive: Bool?
    let unlimited: Topping?
    let cached: Bool?

    var leftGB: Double? { leftKb.map { $0 / 1_048_576 } }
    var fetchedAt: Date { Date(timeIntervalSince1970: Double(fetchedMs) / 1000) }
}

struct Usage: Decodable {
    let buckets: [Bucket]
    let calls: Counter?
    let sms: Counter?
}

struct Bucket: Decodable, Identifiable {
    let key: String
    let label: String
    let usedKb: Double
    let leftKb: Double
    let planKb: Double?
    var id: String { key }
}

struct Counter: Decodable {
    let used: Double
    let left: Double?
    let unit: String?
}

struct Topping: Decodable, Hashable {
    let section: String?
    let name: String
    let remaining: String?
    let expiry: String?
}

struct Catalog: Decodable {
    let fetchedMs: Int64
    let products: [Product]
}

struct Product: Decodable, Identifiable, Hashable {
    let sku: String
    let name: String
    let validity: String?
    let price: String?
    let priceYen: Int?
    let requires3ds: Bool
    let section: String?
    var id: String { sku }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        sku = try c.decode(String.self, forKey: AnyKey("sku"))
        name = try c.decode(String.self, forKey: AnyKey("name"))
        validity = try c.decodeIfPresent(String.self, forKey: AnyKey("validity"))
        price = try c.decodeIfPresent(String.self, forKey: AnyKey("price"))
        priceYen = try c.decodeIfPresent(Int.self, forKey: AnyKey("priceYen"))
        section = try c.decodeIfPresent(String.self, forKey: AnyKey("section"))
        requires3ds = c.bool(snake: "requires_3ds")
    }
}

struct CodeItem: Decodable, Identifiable, Hashable {
    let id: String
    let code: String
    let tag: String
    let note: String
    let status: String
    let addedMs: Int64
    let sentMs: Int64?
    let result: String?
    let masked: String

    var statusLabel: String {
        switch status {
        case "pending": return "未使用"
        case "sent": return "送信済み(結果不明)"
        case "applied": return "適用済み"
        case "rejected": return "受付不可"
        default: return "エラー"
        }
    }
}

struct LogItem: Decodable, Hashable {
    let timeMs: Int64
    let level: String
    let message: String
    var date: Date { Date(timeIntervalSince1970: Double(timeMs) / 1000) }
}

struct LedgerItem: Decodable, Hashable {
    let timeMs: Int64
    let sku: String
    let name: String?
    let priceYen: Int?
    let auto: Bool
    let status: String
    let message: String?
    let challengeUrl: String?
    var date: Date { Date(timeIntervalSince1970: Double(timeMs) / 1000) }
}

struct OrderResult: Decodable {
    let dryRun: Bool
    let needs3ds: Bool
    let challengeUrl: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        dryRun = try c.decodeIfPresent(Bool.self, forKey: AnyKey("dryRun")) ?? false
        challengeUrl = try c.decodeIfPresent(String.self, forKey: AnyKey("challengeUrl"))
        needs3ds = c.bool(snake: "needs_3ds")
    }
}

/// 名前で引くキー。
struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where K == AnyKey {
    /// `requires_3ds` のように「_ の直後が数字」のキーは、convertFromSnakeCase の変換結果が
    /// Foundation の実装によって "requires3ds" / "requires3Ds" と揺れるので、両方を試す。
    func bool(snake key: String) -> Bool {
        let parts = key.split(separator: "_").map(String.init)
        let head = parts.first ?? key
        let tail = parts.dropFirst()
        let candidates = [
            head + tail.joined(),
            head + tail.map { $0.capitalized }.joined(),
            head + tail.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(),
            key,
        ]
        for k in candidates {
            if let v = try? decodeIfPresent(Bool.self, forKey: AnyKey(k)) { return v }
        }
        return false
    }
}

struct CodeApplyResult: Decodable {
    let dryRun: Bool
    let masked: String
    let valid: Bool?
    let result: CodeMessage?
}

struct CodeMessage: Decodable {
    let valid: Bool
    let title: String?
    let subtitle: String?
    let message: String?
}

struct CodesAddResult: Decodable {
    let added: Int
    let duplicates: [String]
    let invalid: [String]
}

struct LoginStep: Decodable {
    let done: Bool?
    let sent: String?
}

extension Double {
    /// KB(1024基準)を見やすく。
    var kbText: String {
        let gb = self / 1_048_576
        if gb >= 1 { return String(format: "%.2fGB", gb) }
        return String(format: "%.0fMB", self / 1024)
    }
}
