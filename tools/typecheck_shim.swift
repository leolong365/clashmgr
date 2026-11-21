// Linux 类型检查用的最小桩件。
// Combine 在 Linux 上不可用，这里只为让 `-typecheck` 通过，
// 不参与 App 构建（GitHub Actions 里编译真实的 Combine/SwiftUI）。
import Foundation

public protocol ObservableObject: AnyObject {}

@propertyWrapper
public final class Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public init(initialValue: Value) { self.wrappedValue = initialValue }
}
