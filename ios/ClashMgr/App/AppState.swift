import Foundation
import Combine

/// 应用根状态。持有存储、设置，以及从当前订阅解析出的配置快照。
///
/// 所有解析都在这个对象里完成并缓存，视图只读它，
/// 避免每个列表行都重新解析 100KB+ 的 YAML。
@MainActor
public final class AppState: ObservableObject {

    public let settings: AppSettings
    public let store: ConfigStore

    /// 当前订阅解析出的配置（nil 表示没有选中订阅或解析失败）。
    @Published public private(set) var config: MihomoConfig?
    @Published public private(set) var currentSubscription: Subscription?

    /// 解析/加载错误提示。
    @Published public var alertMessage: String?
    @Published public var isBusy: Bool = false
    @Published public var busyText: String = ""

    /// 全量测速进度。
    @Published public var latencyProgress: (done: Int, total: Int)?
    /// 测速失败的节点：名字 → 原因。
    @Published public private(set) var latencyFailures: [String: String] = [:]

    private let fetcher = SubscriptionFetcher()
    private let tester = LatencyTester()

    public init(settings: AppSettings = AppSettings(), store: ConfigStore = ConfigStore()) {
        self.settings = settings
        self.store = store
        reloadConfig()
    }

    // MARK: - 配置载入

    /// 重新从磁盘读取当前订阅并解析。
    public func reloadConfig() {
        guard let sub = store.currentSubscription else {
            currentSubscription = nil
            config = nil
            return
        }
        guard let text = try? store.readConfig(sub) else {
            currentSubscription = sub
            config = nil
            alertMessage = "无法读取订阅「\(sub.name)」的配置内容"
            return
        }
        let parsed = MihomoConfig.parse(text)
        currentSubscription = sub
        config = parsed
        if !parsed.warnings.isEmpty {
            // 警告不打断用户，仅在控制台留痕。
            print("[ClashMgr] 解析警告 \(parsed.warnings.count) 条")
        }
    }

    /// 切换当前订阅。
    public func select(_ sub: Subscription) {
        store.select(sub.id)
        store.clearLatencyCache()
        latencyFailures.removeAll()
        reloadConfig()
    }

    // MARK: - 订阅增删改

    /// 从 URL 添加订阅（或刷新已有订阅）。
    public func addFromURL(_ urlString: String, name: String? = nil) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alertMessage = "请输入订阅地址"
            return
        }
        isBusy = true
        busyText = "正在下载订阅…"

        fetcher.fetch(trimmed, userAgent: settings.userAgent) { [weak self] result in
            guard let self = self else { return }
            Task { @MainActor in
                self.isBusy = false
                switch result {
                case .failure(let error):
                    self.alertMessage = error.localizedDescription
                case .success(let fetched):
                    guard !fetched.text.isEmpty else {
                        self.alertMessage = "订阅内容为空"
                        return
                    }
                    let finalName = name?.trimmingCharacters(in: .whitespaces).isEmpty == false
                        ? name!
                        : (fetched.suggestedName ?? SubscriptionFetcher.defaultName(for: trimmed))
                    do {
                        let sub = try self.store.addSubscription(
                            name: finalName,
                            url: trimmed,
                            text: fetched.text,
                            userInfo: fetched.userInfo,
                            etag: fetched.etag,
                            lastModified: fetched.lastModified
                        )
                        self.store.select(sub.id)
                        self.reloadConfig()
                    } catch {
                        self.alertMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    /// 从本地文本导入（粘贴 YAML 或从文件读取）。
    public func addFromText(_ text: String, name: String, url: String? = nil) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alertMessage = "配置内容为空"
            return
        }
        do {
            let sub = try store.addSubscription(
                name: trimmedName.isEmpty ? "本地配置" : trimmedName,
                url: url,
                text: text
            )
            store.select(sub.id)
            reloadConfig()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// 刷新指定订阅。
    public func refresh(_ sub: Subscription) {
        guard let urlString = sub.url else {
            alertMessage = "本地配置无法刷新，请重新导入"
            return
        }
        isBusy = true
        busyText = "正在刷新「\(sub.name)」…"

        fetcher.fetch(urlString, userAgent: settings.userAgent, etag: sub.lastETag) { [weak self] result in
            guard let self = self else { return }
            Task { @MainActor in
                self.isBusy = false
                switch result {
                case .failure(let error):
                    self.alertMessage = "刷新失败：\(error.localizedDescription)"
                case .success(let fetched):
                    // 304 时 text 为空，视为无变更。
                    if fetched.text.isEmpty {
                        self.alertMessage = "订阅无更新"
                        return
                    }
                    var updated = sub
                    updated.userInfo = fetched.userInfo.map(SubscriptionUserInfoCodable.init)
                    updated.lastETag = fetched.etag
                    updated.lastModified = fetched.lastModified
                    do {
                        _ = try self.store.writeConfig(fetched.text, for: updated)
                        if self.store.currentID == sub.id { self.reloadConfig() }
                    } catch {
                        self.alertMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    public func delete(_ sub: Subscription) {
        store.delete(sub.id)
        reloadConfig()
    }

    public func rename(_ sub: Subscription, to newName: String) {
        store.rename(sub.id, to: newName)
        reloadConfig()
    }

    // MARK: - 测速

    /// 全量测速。结果写入 store.latencies（会持久化）。
    public func testAllLatency(nodes: [ProxyNode]? = nil) {
        guard let cfg = config else { return }
        let targets = nodes ?? cfg.proxies
        guard !targets.isEmpty else { return }

        latencyProgress = (0, targets.count)
        latencyFailures.removeAll()

        tester.testAll(
            nodes: targets,
            concurrency: settings.clampedConcurrency,
            timeout: settings.clampedTimeout,
            onProgress: { [weak self] done, total, result in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.latencyProgress = (done, total)
                    if let ms = result.milliseconds {
                        self.store.latencies[result.nodeID] = ms
                        self.latencyFailures.removeValue(forKey: result.nodeID)
                    } else {
                        self.store.latencies.removeValue(forKey: result.nodeID)
                        if let f = result.failure {
                            self.latencyFailures[result.nodeID] = f
                        }
                    }
                }
            },
            completion: { [weak self] latencies, failures in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.store.latencies = latencies
                    self.latencyFailures = failures
                    self.store.persistLatencies()
                    self.latencyProgress = nil
                }
            }
        )
    }

    /// 清空测速结果（延迟数字与失败原因）。
    ///
    /// `latencyFailures` 对外是只读的，视图不能直接改，必须走这个方法。
    public func clearLatencyResults() {
        store.clearLatencyCache()
        latencyFailures.removeAll()
        latencyProgress = nil
    }

    /// 单节点测速。
    public func testSingle(_ node: ProxyNode) {
        tester.testAll(
            nodes: [node],
            concurrency: 1,
            timeout: settings.clampedTimeout,
            onProgress: nil,
            completion: { [weak self] latencies, failures in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let ms = latencies[node.id] {
                        self.store.latencies[node.id] = ms
                        self.latencyFailures.removeValue(forKey: node.id)
                    } else {
                        self.store.latencies.removeValue(forKey: node.id)
                        if let f = failures[node.id] { self.latencyFailures[node.id] = f }
                    }
                    self.store.persistLatencies()
                }
            }
        )
    }

    // MARK: - 导出

    /// 生成导出文本并写到导出目录，返回文件 URL。
    public func exportConfig(keepNodes: Set<String>, includeRules: Bool) -> URL? {
        guard let cfg = config, let sub = currentSubscription else { return nil }
        let result = Exporter().export(cfg, options: .init(
            keepNodeNames: keepNodes,
            includeRules: includeRules
        ))
        let fileName = Exporter.exportFileName(subscriptionName: sub.name)
        let url = store.exportsDirectory.appendingPathComponent(fileName)
        do {
            try result.text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            alertMessage = "导出失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 只生成文本，不落盘（用于直接分享/复制）。
    public func exportText(keepNodes: Set<String>, includeRules: Bool) -> String? {
        guard let cfg = config else { return nil }
        return Exporter().export(cfg, options: .init(
            keepNodeNames: keepNodes,
            includeRules: includeRules
        )).text
    }
}
