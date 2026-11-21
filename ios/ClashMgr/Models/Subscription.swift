import Foundation

/// 订阅流量信息，来自响应头 `subscription-userinfo`。
public struct SubscriptionUserInfo: Equatable {
    /// 已上传字节
    public var upload: Int64?
    /// 已下载字节
    public var download: Int64?
    /// 总流量字节
    public var total: Int64?
    /// 到期时间（Unix 秒）
    public var expire: Int64?

    public init(upload: Int64? = nil, download: Int64? = nil,
                total: Int64? = nil, expire: Int64? = nil) {
        self.upload = upload
        self.download = download
        self.total = total
        self.expire = expire
    }

    /// 解析 `upload=1234; download=5678; total=102400; expire=1700000000`。
    /// mihomo / clash 各机场格式略有差异（逗号分隔、空格缺失等），这里都容忍。
    public static func parse(_ raw: String) -> SubscriptionUserInfo? {
        var info = SubscriptionUserInfo()
        var found = false

        let normalized = raw
            .replacingOccurrences(of: ",", with: ";")
            .replacingOccurrences(of: " ", with: "")

        for pair in normalized.components(separatedBy: ";") {
            let kv = pair.components(separatedBy: "=")
            guard kv.count == 2 else { continue }
            let key = kv[0].lowercased()
            guard let value = Int64(kv[1]) else { continue }
            switch key {
            case "upload": info.upload = value; found = true
            case "download": info.download = value; found = true
            case "total": info.total = value; found = true
            case "expire": info.expire = value; found = true
            default: break
            }
        }
        return found ? info : nil
    }

    public var used: Int64? {
        guard let u = upload, let d = download else {
            return upload ?? download
        }
        return u + d
    }

    /// 已用比例 0...1；total 缺失或为 0 时返回 nil。
    public var usedFraction: Double? {
        guard let t = total, t > 0, let used = used else { return nil }
        return min(1.0, max(0.0, Double(used) / Double(t)))
    }

    public var expireDate: Date? {
        guard let e = expire, e > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(e))
    }

    /// 到期时间是否已过。
    public var isExpired: Bool {
        guard let d = expireDate else { return false }
        return d < Date()
    }
}

/// 一条订阅记录（持久化到磁盘）。
public struct Subscription: Identifiable, Equatable, Codable {
    public var id: UUID
    public var name: String
    /// 远程 URL；本地文件/粘贴导入时为 nil。
    public var url: String?
    /// 该订阅最近一次抓取到的原始配置文本，存盘。
    public var fileName: String
    public var updatedAt: Date
    public var userInfo: SubscriptionUserInfoCodable?
    /// 订阅响应里带的自定义 UA（部分机场会返回 `content-disposition` 或专用头）。
    public var lastETag: String?
    public var lastModified: String?
    /// 节点数量快照，避免列表页每次都要解析。
    public var nodeCount: Int
    public var groupCount: Int
    public var ruleCount: Int

    public init(id: UUID = UUID(), name: String, url: String?, fileName: String,
                updatedAt: Date = Date(), userInfo: SubscriptionUserInfoCodable? = nil,
                lastETag: String? = nil, lastModified: String? = nil,
                nodeCount: Int = 0, groupCount: Int = 0, ruleCount: Int = 0) {
        self.id = id
        self.name = name
        self.url = url
        self.fileName = fileName
        self.updatedAt = updatedAt
        self.userInfo = userInfo
        self.lastETag = lastETag
        self.lastModified = lastModified
        self.nodeCount = nodeCount
        self.groupCount = groupCount
        self.ruleCount = ruleCount
    }

    /// 用于列表副标题：优先显示域名。
    public var hostLabel: String {
        guard let urlString = url, let host = URL(string: urlString)?.host else {
            return "本地配置"
        }
        return host
    }

    public var isRemote: Bool { url != nil }
}

/// `SubscriptionUserInfo` 的 Codable 镜像（原类型用 Optional Int64，直接 Codable 也够，但保持显式）。
public struct SubscriptionUserInfoCodable: Codable, Equatable {
    public var upload: Int64?
    public var download: Int64?
    public var total: Int64?
    public var expire: Int64?

    public init(_ info: SubscriptionUserInfo) {
        self.upload = info.upload
        self.download = info.download
        self.total = info.total
        self.expire = info.expire
    }

    public var asInfo: SubscriptionUserInfo {
        SubscriptionUserInfo(upload: upload, download: download, total: total, expire: expire)
    }
}
