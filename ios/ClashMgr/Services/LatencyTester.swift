import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 节点延迟探测。
///
/// 说明：本 App 不建立隧道，因此无法测量「经过代理的」真实延迟。
/// 这里测的是到节点服务器 `host:port` 的 **TCP 握手往返时间（RTT）**，
/// 用来判断节点是否存活、网络是否可达——这也是各家客户端在没有订阅测速接口时的通行做法。
public final class LatencyTester {

    /// 单个节点的探测结果。
    public struct ProbeResult {
        public let nodeID: String
        /// 毫秒；nil 表示失败。
        public let milliseconds: Int?
        public let failure: String?

        public init(nodeID: String, milliseconds: Int?, failure: String?) {
            self.nodeID = nodeID
            self.milliseconds = milliseconds
            self.failure = failure
        }
    }

    /// 全量测速进度回调。
    public typealias ProgressHandler = (_ completed: Int, _ total: Int, _ latest: ProbeResult) -> Void

    private let queue = DispatchQueue(label: "clashmgr.latency", qos: .userInitiated,
                                      attributes: .concurrent)

    public init() {}

    // MARK: - 批量

    /// 并发测速。
    /// - Parameters:
    ///   - nodes: 待测节点
    ///   - concurrency: 并发数（1...32）
    ///   - timeout: 单节点超时秒数
    ///   - onProgress: 主线程回调进度
    ///   - completion: 主线程回调全部结果（nodeID → 毫秒）与失败原因
    public func testAll(nodes: [ProxyNode],
                        concurrency: Int,
                        timeout: Double,
                        onProgress: ProgressHandler? = nil,
                        completion: @escaping ([String: Int], [String: String]) -> Void) {

        let total = nodes.count
        guard total > 0 else {
            DispatchQueue.main.async { completion([:], [:]) }
            return
        }

        let limit = max(1, min(32, concurrency))
        let semaphore = DispatchSemaphore(value: limit)
        let group = DispatchGroup()
        let lock = NSLock()

        var latencies: [String: Int] = [:]
        var failures: [String: String] = [:]
        var completed = 0

        for node in nodes {
            group.enter()
            semaphore.wait()

            queue.async {
                let result = self.probe(node, timeout: timeout)

                lock.lock()
                if let ms = result.milliseconds {
                    latencies[node.id] = ms
                } else if let f = result.failure {
                    failures[node.id] = f
                }
                completed += 1
                let snapshot = completed
                lock.unlock()

                if let onProgress = onProgress {
                    DispatchQueue.main.async { onProgress(snapshot, total, result) }
                }
                semaphore.signal()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            lock.lock()
            let finalLatencies = latencies
            let finalFailures = failures
            lock.unlock()
            completion(finalLatencies, finalFailures)
        }
    }

    /// 单节点测速（同步，需在后台队列调用）。
    public func probe(_ node: ProxyNode, timeout: Double) -> ProbeResult {
        let host = node.server
        let port = node.port
        guard !host.isEmpty, port > 0, port <= 65535 else {
            return ProbeResult(nodeID: node.id, milliseconds: nil, failure: "地址无效")
        }

        let timeoutMs = Int32(max(1.0, timeout) * 1000)
        let started = DispatchTime.now().uptimeNanoseconds
        let outcome = LatencyTester.tcpHandshake(host: host, port: port, timeoutMs: timeoutMs)

        switch outcome {
        case .success:
            let elapsedNs = DispatchTime.now().uptimeNanoseconds - started
            let ms = Int(elapsedNs / 1_000_000)
            return ProbeResult(nodeID: node.id, milliseconds: max(1, ms), failure: nil)
        case .failure(let message):
            return ProbeResult(nodeID: node.id, milliseconds: nil, failure: message)
        }
    }

    // MARK: - TCP 握手

    enum HandshakeOutcome {
        case success
        case failure(String)
    }

    /// 非阻塞 `connect` + `poll` 等可写，再读 `SO_ERROR`。
    static func tcpHandshake(host: String, port: Int, timeoutMs: Int32) -> HandshakeOutcome {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = sockStreamType
        hints.ai_protocol = Int32(IPPROTO_TCP)

        var result: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)
        let status = getaddrinfo(host, portString, &hints, &result)
        guard status == 0, let head = result else {
            return .failure("域名解析失败")
        }
        defer { freeaddrinfo(head) }

        var lastFailure = "无法连接"
        var cursor: UnsafeMutablePointer<addrinfo>? = head

        while let info = cursor {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                let outcome = connectWithTimeout(fd: fd,
                                                addr: info.pointee.ai_addr,
                                                addrLen: info.pointee.ai_addrlen,
                                                timeoutMs: timeoutMs)
                close(fd)
                if case .success = outcome {
                    return .success
                }
                if case .failure(let message) = outcome {
                    lastFailure = message
                }
            }
            cursor = info.pointee.ai_next
        }
        return .failure(lastFailure)
    }

    /// `SOCK_STREAM` 在 Darwin 上是 Int32，在 Linux 上是 `__socket_type` 枚举。
    private static var sockStreamType: Int32 {
        #if canImport(Darwin)
        return Int32(SOCK_STREAM)
        #else
        return Int32(SOCK_STREAM.rawValue)
        #endif
    }

    private static func connectWithTimeout(fd: Int32,
                                           addr: UnsafeMutablePointer<sockaddr>?,
                                           addrLen: socklen_t,
                                           timeoutMs: Int32) -> HandshakeOutcome {
        guard let addr = addr else { return .failure("地址无效") }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        let rc = connect(fd, addr, addrLen)
        if rc == 0 {
            return .success
        }
        if errno != EINPROGRESS {
            return .failure("连接被拒绝")
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, timeoutMs)
        if ready == 0 {
            return .failure("超时")
        }
        if ready < 0 {
            return .failure("等待可写失败")
        }

        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 else {
            return .failure("连接失败")
        }
        if soError != 0 {
            return .failure("连接被拒绝")
        }
        return .success
    }
}
