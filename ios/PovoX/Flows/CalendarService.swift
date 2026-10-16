import CoreLocation
import CryptoKit
import EventKit
import Foundation

/// カレンダーの予定を読む(読むだけ。書き込み・外への送信はしない)。
/// 予定は「今日のプラン」と、オートメーションの「予定の前」に使う。
final class CalendarService {
    private let store = EKEventStore()
    /// UI テスト・デモ用の予定(-demoCalendar)。設定されていれば EventKit を使わない。
    var demoEvents: [CalEvent]?

    enum Access: Equatable {
        case authorized, denied, notDetermined
    }

    var access: Access {
        if demoEvents != nil { return .authorized }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    var authorized: Bool { access == .authorized }

    /// 予定を読む許可を求める(iOS 17: フルアクセス)。
    func requestAccess() async -> Bool {
        if demoEvents != nil { return true }
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    /// 今日の0時から days 日分の予定。
    func events(days: Int = 2, now: Date = Date()) -> [CalEvent] {
        let start = DayPlanner.tokyo.startOfDay(for: now)
        let end = DayPlanner.tokyo.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days) * 86400)
        return events(from: start, to: end)
    }

    /// start〜end の予定(学習には過去の予定も使う)。
    func events(from start: Date, to end: Date) -> [CalEvent] {
        if let demo = demoEvents { return demo.filter { $0.end > start && $0.start < end } }
        guard authorized else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).prefix(3000).compactMap { e in
            guard let s = e.startDate, let en = e.endDate else { return nil }
            // 「予定なし(空き時間)」にしている予定は外出とみなさない
            if e.availability == .free && !e.isAllDay { return nil }
            return CalEvent(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "予定",
                            location: e.location ?? e.structuredLocation?.title,
                            startMs: Int64(s.timeIntervalSince1970 * 1000), endMs: Int64(en.timeIntervalSince1970 * 1000),
                            allDay: e.isAllDay, calendar: e.calendar?.title)
        }
    }

    /// 検証用: 過去 daysBack 日〜先 daysAhead 日の予定を、EventKit の生の項目のまま(端末の外には送らない。
    /// 書き出すかは利用者が共有シートで決める)。redact なら、タイトル・場所・メモは同じ文字なら同じになる短い記号に置き換える。
    func rawEvents(daysBack: Int = 90, daysAhead: Int = 2, redact: Bool, now: Date = Date()) -> [[String: Any]] {
        func hide(_ s: String?) -> Any {
            guard let s, !s.isEmpty else { return NSNull() }
            guard redact else { return s }
            let d = SHA256.hash(data: Data(s.utf8))
            return "h:" + d.prefix(6).map { String(format: "%02x", $0) }.joined()
        }
        if let demo = demoEvents {
            return demo.map { e in
                ["id": e.id, "title": hide(e.title), "location": hide(e.location), "startMs": e.startMs, "endMs": e.endMs,
                 "allDay": e.allDay, "calendar": e.calendar ?? "", "availability": "busy", "status": "confirmed",
                 "selfStatus": "none", "recurring": false, "demo": true]
            }
        }
        guard authorized else { return [] }
        let start = DayPlanner.tokyo.date(byAdding: .day, value: -daysBack, to: DayPlanner.tokyo.startOfDay(for: now)) ?? now
        let end = DayPlanner.tokyo.date(byAdding: .day, value: daysAhead + 1, to: DayPlanner.tokyo.startOfDay(for: now)) ?? now
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).prefix(5000).map { e in
            var d: [String: Any] = [
                "id": e.eventIdentifier ?? "",
                "title": hide(e.title),
                "location": hide(e.location),
                "startMs": Int64((e.startDate?.timeIntervalSince1970 ?? 0) * 1000),
                "endMs": Int64((e.endDate?.timeIntervalSince1970 ?? 0) * 1000),
                "allDay": e.isAllDay,
                "calendar": hide(e.calendar?.title),
                "calendarSource": CalendarService.sourceName(CalendarService.source(of: e)?.sourceType),
                "availability": CalendarService.availabilityName(e.availability),
                "status": CalendarService.statusName(e.status),
                "recurring": e.hasRecurrenceRules,
                "detached": e.isDetached,
                "attendees": e.attendees?.count ?? 0,
                "selfStatus": CalendarService.participationName(e.attendees?.first { $0.isCurrentUser }?.participantStatus),
                "hasNotes": !(e.notes ?? "").isEmpty,
                "notesTags": CalendarService.tags(e.notes),
                "hasURL": e.url != nil,
            ]
            if let sl = e.structuredLocation {
                var loc: [String: Any] = ["title": hide(sl.title)]
                if let g = sl.geoLocation, !redact {
                    loc["lat"] = g.coordinate.latitude
                    loc["lon"] = g.coordinate.longitude
                }
                d["structuredLocation"] = loc
            }
            return d
        }
    }

    /// メモの中の「#…」(N1 の材料。本文は出さない)。
    static func tags(_ notes: String?) -> [String] {
        guard let notes else { return [] }
        return notes.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "　" })
            .filter { $0.hasPrefix("#") && $0.count > 1 }
            .prefix(10)
            .map { String($0.prefix(30)) }
    }

    static func availabilityName(_ a: EKEventAvailability) -> String {
        switch a {
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        default: return "notSupported"
        }
    }

    static func statusName(_ s: EKEventStatus) -> String {
        switch s {
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        default: return "none"
        }
    }

    static func participationName(_ p: EKParticipantStatus?) -> String {
        guard let p else { return "none" }
        switch p {
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .pending: return "pending"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "inProcess"
        default: return "unknown"
        }
    }

    static func source(of e: EKEvent) -> EKSource? {
        let src: EKSource? = e.calendar?.source
        return src
    }

    static func sourceName(_ t: EKSourceType?) -> String {
        guard let t else { return "unknown" }
        switch t {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "calDAV"
        case .mobileMe: return "iCloud"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        default: return "other"
        }
    }

    /// UI テスト・デモ用: 今日の昼〜夜のライブと、明日の歯医者。
    static func demo(now: Date = Date()) -> [CalEvent] {
        let d0 = DayPlanner.tokyo.startOfDay(for: now)
        func ms(_ h: Double, day: Double = 0) -> Int64 { Int64((d0.timeIntervalSince1970 + day * 86400 + h * 3600) * 1000) }
        // 今が遅い時間でも「これから」の予定になるよう、今から2時間後に始まる
        let nowH = now.timeIntervalSince(d0) / 3600
        let start = min(max(13, nowH.rounded(.up) + 2), 22)
        return [
            CalEvent(id: "demo-live", title: "ライブ", location: "大阪城ホール", startMs: ms(start), endMs: ms(start + 4), allDay: false, calendar: "デモ"),
            CalEvent(id: "demo-zoom", title: "オンライン会議(Zoom)", location: "https://zoom.us", startMs: ms(10), endMs: ms(11), allDay: false, calendar: "デモ"),
            CalEvent(id: "demo-dentist", title: "歯医者", location: "梅田", startMs: ms(10, day: 1), endMs: ms(11, day: 1), allDay: false, calendar: "デモ"),
        ]
    }
}
