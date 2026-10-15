import SwiftUI
import UIKit

/// 色と形。povo の黄色を差し色に、あとは落ち着いた無彩色でまとめる(ダークモード対応)。
enum Theme {
    /// povo の黄色(公式アプリの値)。
    static let yellow = Color(red: 1.0, green: 0.961, blue: 0.0)
    /// 文字の上に置ける黄色(ライトでは少し濃く)。
    static let accent = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(red: 1.0, green: 0.93, blue: 0.2, alpha: 1) : UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
    })
    static let ink = Color.primary
    static let bg = Color(UIColor.systemGroupedBackground)
    static let card = Color(UIColor.secondarySystemGroupedBackground)
    static let groove = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 0.24, alpha: 1) : UIColor(red: 0.925, green: 0.941, blue: 0.957, alpha: 1)
    })
    static let danger = Color(red: 0.87, green: 0.2, blue: 0.22)
    static let ok = Color(red: 0.16, green: 0.62, blue: 0.36)
    static let warn = Color(red: 0.95, green: 0.55, blue: 0.1)
    static let radius: CGFloat = 20
}

/// 角丸のカード。
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    var accessory: AnyView?
    let content: Content

    init(_ title: String? = nil, systemImage: String? = nil, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || accessory != nil {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    if let title {
                        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let accessory { accessory }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

/// 黒(ダークでは白)の主ボタン。
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(Color(UIColor.systemBackground))
            .background(Color.primary.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.3),
                        in: RoundedRectangle(cornerRadius: 25, style: .continuous))
    }
}

/// 灰色の副ボタン。
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(.primary)
            .background(Theme.groove.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// 小さな丸い札。
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary
    var filled = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(filled ? Color.black : tint)
        .background(filled ? AnyShapeStyle(Theme.yellow) : AnyShapeStyle(tint.opacity(0.12)), in: Capsule())
    }
}

/// 細い横棒のメーター。
struct MeterBar: View {
    let fraction: Double
    var tint: Color = Theme.yellow

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.groove)
                Capsule().fill(tint)
                    .frame(width: max(6, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 8)
    }
}

/// 下から出る短い知らせ。
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
            .padding(.horizontal, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("toast")
    }
}

extension OutcomeStatus {
    var icon: String {
        switch self {
        case .done: return "checkmark.circle.fill"
        case .queued: return "bell.badge.fill"
        case .dryRun: return "testtube.2"
        case .simulated: return "sparkles"
        case .refused: return "hand.raised.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "minus.circle"
        case .notified: return "bell.fill"
        }
    }

    var tint: Color {
        switch self {
        case .done: return Theme.ok
        case .queued: return Theme.warn
        case .dryRun, .simulated: return .purple
        case .refused: return .secondary
        case .failed: return Theme.danger
        case .skipped: return .secondary
        case .notified: return .blue
        }
    }

    var label: String {
        switch self {
        case .done: return "実行"
        case .queued: return "確認待ち"
        case .dryRun: return "試運転"
        case .simulated: return "予定"
        case .refused: return "見送り"
        case .failed: return "失敗"
        case .skipped: return "なし"
        case .notified: return "通知"
        }
    }
}

extension ActionMode {
    var label: String {
        switch self {
        case .off: return "しない"
        case .confirm: return "通知で確認"
        case .auto: return "自動"
        }
    }
}

extension RunRecord: Identifiable {}
extension PendingAction: Identifiable {}
extension CodeEntry: Identifiable {}
extension Product: Identifiable {
    public var id: String { sku }
}
