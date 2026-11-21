import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 订阅抓取与导入。纯 URLSession，无第三方依赖。
public final class SubscriptionFetcher {

    public enum FetchError: LocalizedError {
        case badURL(String)
        case http(Int)
        case empty
        case notUTF8
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .badURL(let s): return "订阅地址无效：\(s)"
            case .http(let code): return "服务器返回 HTTP \(code)"
            case .empty: return "订阅内容为空"
            case .notUTF8: return "订阅内容不是 UTF-8 文本"
            case .transport(let m): return "网络错误：\(m)"
            }
        }
    }

    /// 一次抓取的结果，含响应头里解析出的流量信息与缓存标识。
    public struct FetchResult {
        public var text: String
        public var userInfo: SubscriptionUserInfo?
        public var etag: String?
        public var lastModified: String?
        /// 服务端建议的订阅名（`content-disposition` 或 `profile-title`）。
        public var suggestedName: String?
    }

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let s = session {
            self.session = s
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 60
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    /// 抓取远程订阅。
    /// - Parameters:
    ///   - urlString: 订阅地址
    ///   - userAgent: 请求 UA，多数机场据此决定返回 Clash 还是 V2Ray 格式
    ///   - etag: 上次响应的 ETag，用于条件请求
    public func fetch(_ urlString: String, userAgent: String,
                      etag: String? = nil,
                      completion: @escaping (Result<FetchResult, Error>) -> Void) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil else {
            completion(.failure(FetchError.badURL(urlString)))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/yaml, text/yaml, */*", forHTTPHeaderField: "Accept")
        if let e = etag, !e.isEmpty {
            req.setValue(e, forHTTPHeaderField: "If-None-Match")
        }

        session.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(FetchError.transport(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(FetchError.transport("无 HTTP 响应")))
                return
            }

            // 304 表示未变更，交由调用方保留旧内容。
            if http.statusCode == 304 {
                completion(.success(FetchResult(text: "", userInfo: nil,
                                                etag: etag, lastModified: nil,
                                                suggestedName: nil)))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(FetchError.http(http.statusCode)))
                return
            }
            guard let data = data, !data.isEmpty else {
                completion(.failure(FetchError.empty))
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                completion(.failure(FetchError.notUTF8))
                return
            }

            let info = self.parseUserInfo(http)
            let name = self.parseSuggestedName(http, url: url)
            completion(.success(FetchResult(
                text: text,
                userInfo: info,
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                suggestedName: name
            )))
        }.resume()
    }

    private func parseUserInfo(_ http: HTTPURLResponse) -> SubscriptionUserInfo? {
        let candidates = ["subscription-userinfo", "SUBSCRIPTION-USERINFO",
                          "X-Subscription-Userinfo", "x-subscription-userinfo"]
        for key in candidates {
            if let raw = http.value(forHTTPHeaderField: key),
               let info = SubscriptionUserInfo.parse(raw) {
                return info
            }
        }
        return nil
    }

    /// 从 `content-disposition` 的 `filename*=UTF-8''xxx` 或 `profile-title` 头取名字。
    private func parseSuggestedName(_ http: HTTPURLResponse, url: URL) -> String? {
        if let title = http.value(forHTTPHeaderField: "profile-title") ??
            http.value(forHTTPHeaderField: "Profile-Title"), !title.isEmpty {
            return title
        }
        guard let cd = http.value(forHTTPHeaderField: "Content-Disposition") else {
            return nil
        }
        // filename*=UTF-8''name 形式
        if let range = cd.range(of: "''") {
            let tail = String(cd[range.upperBound...])
            let name = tail.components(separatedBy: ";").first ?? tail
            let decoded = name.removingPercentEncoding ?? name
            if !decoded.isEmpty { return decoded }
        }
        if let range = cd.range(of: "filename=") {
            var name = String(cd[range.upperBound...])
            name = name.components(separatedBy: ";").first ?? name
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// 从订阅 URL 推导一个默认显示名：用 host。
    public static func defaultName(for urlString: String) -> String {
        guard let host = URL(string: urlString)?.host else {
            return "新订阅"
        }
        return host
    }
}
