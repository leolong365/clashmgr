import Foundation

/// 用户设置，持久化到 UserDefaults。
public final class AppSettings: ObservableObject {

    private enum Key {
        static let userAgent = "settings.userAgent"
        static let timeout = "settings.timeout"
        static let concurrency = "settings.concurrency"
        static let refreshInterval = "settings.refreshInterval"
        static let latencyURL = "settings.latencyURL"
        static let testHost = "settings.testHost"
    }

    /// 缺省 UA。多数机场按 UA 返回不同格式（clash / clash.meta / v2rayN）。
    public static let defaultUserAgent = "clash.meta"

    private let defaults: UserDefaults

    @Published public var userAgent: String {
        didSet { defaults.set(userAgent, forKey: Key.userAgent) }
    }

    /// 单个节点测速超时（秒）。
    @Published public var timeout: Double {
        didSet { defaults.set(timeout, forKey: Key.timeout) }
    }

    /// 全量测速并发数。
    @Published public var concurrency: Int {
        didSet { defaults.set(concurrency, forKey: Key.concurrency) }
    }

    /// 默认刷新周期（小时）；0 表示不自动刷新。
    @Published public var refreshIntervalHours: Int {
        didSet { defaults.set(refreshIntervalHours, forKey: Key.refreshInterval) }
    }

    /// 测速用的 HTTP 探测地址（仅展示用途，TCP 探测不使用）。
    @Published public var latencyTestURL: String {
        didSet { defaults.set(latencyTestURL, forKey: Key.latencyURL) }
    }

    /// 额外测试域名（可选）。
    @Published public var extraTestHost: String {
        didSet { defaults.set(extraTestHost, forKey: Key.testHost) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.userAgent = defaults.string(forKey: Key.userAgent) ?? AppSettings.defaultUserAgent
        let t = defaults.double(forKey: Key.timeout)
        self.timeout = t > 0 ? t : 5.0
        let c = defaults.integer(forKey: Key.concurrency)
        self.concurrency = c > 0 ? c : 8
        self.refreshIntervalHours = defaults.integer(forKey: Key.refreshInterval)
        self.latencyTestURL = defaults.string(forKey: Key.latencyURL)
            ?? "https://www.gstatic.com/generate_204"
        self.extraTestHost = defaults.string(forKey: Key.testHost) ?? ""
    }

    /// 允许的并发范围。
    public var clampedConcurrency: Int {
        min(32, max(1, concurrency))
    }

    public var clampedTimeout: Double {
        min(30, max(1, timeout))
    }
}
