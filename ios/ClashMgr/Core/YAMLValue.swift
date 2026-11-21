import Foundation

/// 保序键值对。Swift 的 Dictionary 无序，而 YAML 映射顺序对 diff / 导出至关重要。
public struct YAMLPair: Equatable {
    public var key: String
    public var value: YAMLValue
    public init(_ key: String, _ value: YAMLValue) {
        self.key = key
        self.value = value
    }
}

/// 保序映射。
public struct YAMLMap: Equatable {
    public private(set) var pairs: [YAMLPair]

    public init() { pairs = [] }
    public init(_ pairs: [YAMLPair]) { self.pairs = pairs }

    public var keys: [String] { pairs.map(\.key) }
    public var count: Int { pairs.count }
    public var isEmpty: Bool { pairs.isEmpty }

    public subscript(key: String) -> YAMLValue? {
        get { pairs.first(where: { $0.key == key })?.value }
        set {
            if let idx = pairs.firstIndex(where: { $0.key == key }) {
                if let v = newValue {
                    pairs[idx].value = v
                } else {
                    pairs.remove(at: idx)
                }
            } else if let v = newValue {
                pairs.append(YAMLPair(key, v))
            }
        }
    }

    public func contains(_ key: String) -> Bool {
        pairs.contains(where: { $0.key == key })
    }

    public mutating func remove(_ key: String) {
        pairs.removeAll(where: { $0.key == key })
    }

    public mutating func rename(_ key: String, to newKey: String) {
        guard let idx = pairs.firstIndex(where: { $0.key == key }) else { return }
        pairs[idx].key = newKey
    }
}

/// YAML 值。与解析器/发射器一一对应。
public enum YAMLValue: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([YAMLValue])
    case object(YAMLMap)

    // MARK: - 便捷访问

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s):
            switch s.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: return nil
            }
        case .int(let i): return i != 0
        default: return nil
        }
    }

    public var arrayValue: [YAMLValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var mapValue: YAMLMap? {
        if case .object(let m) = self { return m }
        return nil
    }

    /// 把任意标量转成可展示的文本（数字/布尔也转）。用于 UI 显示。
    public var scalarText: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return YAMLValue.formatDouble(d)
        case .string(let s): return s
        case .array(let a):
            return a.map(\.scalarText).joined(separator: ", ")
        case .object:
            return ""
        }
    }

    /// 字符串数组走这里；标量也容忍（订阅里 `alpn: h2` 与 `alpn: [h2]` 都存在）。
    public var stringList: [String] {
        switch self {
        case .array(let a): return a.map(\.scalarText)
        case .null: return []
        default: return [scalarText]
        }
    }

    static func formatDouble(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 {
            return String(format: "%.1f", d)
        }
        return "\(d)"
    }
}

// MARK: - 构造辅助

extension YAMLValue {
    public static func stringOrNull(_ s: String?) -> YAMLValue {
        guard let s else { return .null }
        return .string(s)
    }

    public static func intOrNull(_ i: Int?) -> YAMLValue {
        guard let i else { return .null }
        return .int(i)
    }
}
