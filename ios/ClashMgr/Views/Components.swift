import SwiftUI
import UIKit

// MARK: - 延迟色块

/// 延迟数值 → 颜色。绿 <200ms，黄 <500ms，红其余，灰未测。
public enum LatencyStyle {

    public static func color(for milliseconds: Int?) -> Color {
        guard let ms = milliseconds else { return .secondary.opacity(0.35) }
        if ms < 200 { return Color.green }
        if ms < 500 { return Color.yellow }
        return Color.red
    }

    public static func text(for milliseconds: Int?) -> String {
        guard let ms = milliseconds else { return "—" }
        return "\(ms) ms"
    }
}

/// 延迟徽标。
public struct LatencyBadge: View {
    public let milliseconds: Int?
    public let failed: Bool

    public init(milliseconds: Int?, failed: Bool = false) {
        self.milliseconds = milliseconds
        self.failed = failed
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(failed ? Color.red.opacity(0.85) : LatencyStyle.color(for: milliseconds))
                .frame(width: 7, height: 7)
            Text(failed ? "失败" : LatencyStyle.text(for: milliseconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(failed ? Color.red : Color.secondary)
        }
    }
}

// MARK: - 流量条

/// 订阅流量使用进度条。
public struct TrafficBar: View {
    public let used: Int64
    public let total: Int64
    public let expireText: String?

    public init(info: SubscriptionUserInfo) {
        self.used = info.used ?? 0
        self.total = info.total ?? 0
        if let date = info.expireDate {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            self.expireText = "到期 " + f.string(from: date)
        } else {
            self.expireText = nil
        }
    }

    /// 是否值得显示（没有总量信息就不显示）。
    public static func isAvailable(_ info: SubscriptionUserInfo) -> Bool {
        guard let t = info.total, t > 0 else { return false }
        return info.used != nil
    }

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1.0, max(0.0, Double(used) / Double(total)))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(fraction > 0.9 ? Color.red : Color.accentColor)
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 5)

            HStack(spacing: 6) {
                Text("\(Self.bytes(used)) / \(Self.bytes(total))")
                if let e = expireText {
                    Text("·")
                    Text(e)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    /// 人类可读的字节数。
    public static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = Double(value)
        var idx = 0
        while v >= 1024 && idx < units.count - 1 {
            v /= 1024
            idx += 1
        }
        if idx == 0 {
            return "\(value) B"
        }
        return String(format: "%.2f %@", v, units[idx])
    }
}

// MARK: - 空状态

public struct EmptyStateView: View {
    public let icon: String
    public let title: String
    public let message: String
    public var actionTitle: String?
    public var action: (() -> Void)?

    public init(icon: String, title: String, message: String,
                actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if let t = actionTitle, let a = action {
                Button(t, action: a)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 搜索过滤

/// 供列表页共用的搜索字段。
public struct SearchField: View {
    @Binding public var text: String
    public var placeholder: String

    public init(text: Binding<String>, placeholder: String = "搜索") {
        self._text = text
        self.placeholder = placeholder
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
