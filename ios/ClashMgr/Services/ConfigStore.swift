import Foundation

/// 订阅与配置的本地存储。所有文件都在 App 沙盒的 Documents 下，纯本地，无网络。
///
/// 目录布局：
///   Documents/subscriptions/<uuid>.yaml   订阅原始配置
///   Documents/subscriptions.json          订阅元数据列表
///   Documents/current.json                当前选中订阅的 id 与选中组
public final class ConfigStore: ObservableObject {

    public enum StoreError: LocalizedError {
        case notFound
        case ioFailure(String)

        public var errorDescription: String? {
            switch self {
            case .notFound: return "订阅不存在"
            case .ioFailure(let m): return "存储失败：\(m)"
            }
        }
    }

    @Published public private(set) var subscriptions: [Subscription] = []
    @Published public private(set) var currentID: UUID?
    /// 全量测速结果：节点名 → 延迟毫秒。nil 表示未测。
    @Published public var latencies: [String: Int] = [:]

    private let root: URL
    private let subsDir: URL

    private var subscriptionsIndexURL: URL { root.appendingPathComponent("subscriptions.json") }
    private var currentFileURL: URL { root.appendingPathComponent("current.json") }
    private var latenciesURL: URL { root.appendingPathComponent("latencies.json") }

    public init(root: URL? = nil) {
        let base: URL
        if let r = root {
            base = r
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            base = docs.appendingPathComponent("ClashMgr", isDirectory: true)
        }
        self.root = base
        self.subsDir = base.appendingPathComponent("subscriptions", isDirectory: true)

        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)

        loadAll()
    }

    // MARK: - 载入 / 落盘

    private func loadAll() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: subscriptionsIndexURL),
           let list = try? dec.decode([Subscription].self, from: data) {
            subscriptions = list
        }
        if let data = try? Data(contentsOf: currentFileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let s = obj["id"] as? String {
            currentID = UUID(uuidString: s)
        }
        if let data = try? Data(contentsOf: latenciesURL),
           let map = try? JSONDecoder().decode([String: Int].self, from: data) {
            latencies = map
        }
    }

    private func saveIndex() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(subscriptions) else { return }
        try? data.write(to: subscriptionsIndexURL, options: .atomic)
    }

    public func select(_ id: UUID?) {
        currentID = id
        let obj: [String: Any] = ["id": id?.uuidString ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: currentFileURL, options: .atomic)
        }
    }

    /// 保存测速结果，方便下次打开直接看到颜色。
    public func persistLatencies() {
        guard let data = try? JSONEncoder().encode(latencies) else { return }
        try? data.write(to: latenciesURL, options: .atomic)
    }

    // MARK: - 订阅文件

    public func fileURL(for sub: Subscription) -> URL {
        subsDir.appendingPathComponent(sub.fileName)
    }

    public func readConfig(_ sub: Subscription) throws -> String {
        let url = fileURL(for: sub)
        guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.notFound }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw StoreError.ioFailure(error.localizedDescription)
        }
    }

    @discardableResult
    public func writeConfig(_ text: String, for sub: Subscription) throws -> Subscription {
        var updated = sub
        let url = fileURL(for: updated)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw StoreError.ioFailure(error.localizedDescription)
        }

        let cfg = MihomoConfig.parse(text)
        updated.updatedAt = Date()
        updated.nodeCount = cfg.proxies.count
        updated.groupCount = cfg.groups.count
        updated.ruleCount = cfg.rules.count
        if let idx = subscriptions.firstIndex(where: { $0.id == updated.id }) {
            subscriptions[idx] = updated
        }
        saveIndex()
        return updated
    }

    /// 新增订阅。`text` 为配置正文，落盘后记录元数据。
    @discardableResult
    public func addSubscription(name: String, url: String?, text: String,
                                userInfo: SubscriptionUserInfo? = nil,
                                etag: String? = nil,
                                lastModified: String? = nil) throws -> Subscription {
        let id = UUID()
        let fileName = id.uuidString + ".yaml"
        let cfg = MihomoConfig.parse(text)

        let sub = Subscription(
            id: id,
            name: name,
            url: url,
            fileName: fileName,
            updatedAt: Date(),
            userInfo: userInfo.map(SubscriptionUserInfoCodable.init),
            lastETag: etag,
            lastModified: lastModified,
            nodeCount: cfg.proxies.count,
            groupCount: cfg.groups.count,
            ruleCount: cfg.rules.count
        )

        let target = subsDir.appendingPathComponent(fileName)
        do {
            try text.write(to: target, atomically: true, encoding: .utf8)
        } catch {
            throw StoreError.ioFailure(error.localizedDescription)
        }

        subscriptions.append(sub)
        saveIndex()
        if currentID == nil { select(id) }
        return sub
    }

    /// 重命名订阅。
    public func rename(_ id: UUID, to newName: String) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        subscriptions[idx].name = trimmed
        saveIndex()
    }

    /// 删除订阅，同时删掉其配置文件。
    public func delete(_ id: UUID) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let sub = subscriptions[idx]
        try? FileManager.default.removeItem(at: fileURL(for: sub))
        subscriptions.remove(at: idx)
        saveIndex()

        if currentID == id {
            select(subscriptions.first?.id)
        }
    }

    public func subscription(_ id: UUID) -> Subscription? {
        subscriptions.first(where: { $0.id == id })
    }

    public var currentSubscription: Subscription? {
        guard let id = currentID else { return nil }
        return subscription(id)
    }

    /// 读取当前订阅解析后的配置。
    public func currentConfig() -> (Subscription, MihomoConfig)? {
        guard let sub = currentSubscription,
              let text = try? readConfig(sub) else { return nil }
        return (sub, MihomoConfig.parse(text))
    }

    /// 清空所有缓存（测速结果），保留订阅。
    public func clearLatencyCache() {
        latencies.removeAll()
        persistLatencies()
    }

    /// 供文件 App 访问的导出目录。
    public var exportsDirectory: URL {
        let dir = root.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
