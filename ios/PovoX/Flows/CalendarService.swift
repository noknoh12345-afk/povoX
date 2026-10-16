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
        if let demo = demoEvents { return demo }
        guard authorized else { return [] }
        let start = DayPlanner.tokyo.startOfDay(for: now)
        let end = DayPlanner.tokyo.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days) * 86400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).prefix(200).compactMap { e in
            guard let s = e.startDate, let en = e.endDate else { return nil }
            // 「予定なし(空き時間)」にしている予定は外出とみなさない
            if e.availability == .free && !e.isAllDay { return nil }
            return CalEvent(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "予定",
                            location: e.location ?? e.structuredLocation?.title,
                            startMs: Int64(s.timeIntervalSince1970 * 1000), endMs: Int64(en.timeIntervalSince1970 * 1000),
                            allDay: e.isAllDay, calendar: e.calendar?.title)
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
