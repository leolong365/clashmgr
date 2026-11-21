# bug.md — ClashMgr 踩坑记录

> 记录时间：2026-11-21
> 环境：Windows 10/11（`E:\clash`），无 macOS、无 Swift 工具链、无付费 Apple Developer 账号
> 教训价值：标 ★ 的是会重复踩的坑

---

## 一、产品决策类

### 1. ★ iOS 系统级 VPN 需要付费账号，免费侧载永远拿不到
- 现象：想在 iOS 上复刻 CMFA 的「启动/停止 + 全局代理」。
- 原因：iOS 的全局代理必须用 `NEPacketTunnelProvider`，它依赖
  `com.apple.developer.networking.networkextension` entitlement，**只对付费 Apple Developer Program 开放**。
  免费 Apple ID 自签的 App 拿不到任何 entitlement，`NETunnelProviderManager.saveToPreferences` 必然失败。
- 结论：用户明确「没有，且不打算买」→ 放弃 A/B 方案，改走方案 C（无隧道订阅管家）。
- 参考：https://www.volcengine.com/article/1374792 、 https://jbsite.kr/pc/sideloadly/

### 2. 免费账号侧载的现实限制（已告知用户）
- 7 天到期需重签
- 最多同时 3 个 App
- 每周 10 个 App ID
- 本项目无 entitlement，所以这些限制**不阻塞功能**，只影响重签频率。

---

## 二、环境类

### 3. ★ Windows 上装不了 Swift 工具链
- 尝试过：官方 `swift-xxx-windows.exe` 静默安装 → 返回 `EXIT=-2147019873`（`0x800706BF`）。
- 根因：缺 MSVC / `vswhere` / Windows SDK（`swiftc` 依赖 Visual Studio 的 C++ 工具链和链接器）。
- 也确认过：无 Docker、WSL 未安装。
- **绕法见第 4 条**。

### 4. ★★ 用 Godbolt Compiler Explorer 代替本地 Swift（本项目的核心绕法）
- 端点：`POST https://godbolt.org/api/compiler/swift59/compile`
- 必须走代理 `http://127.0.0.1:7897`（`urllib.request.ProxyHandler`）
- **三层门禁**：
  1. `-typecheck` → 抓类型错误（只能查 Foundation-only 代码）
  2. `-parse` → 抓语法错误（SwiftUI 文件只能用这个，因为 Linux 无 SwiftUI/UIKit 模块）
  3. `filters: {"execute": True}` → **真编译成可执行并运行**，读 `execResult.stdout`
- 坑 A：判构建成功**不能用 `buildResult`**（它只在部分响应里出现），要用 `res['code']==0 and execResult is not None`。
  误用会永远报 `BUILD FAILED exit=0`。
- 坑 B：`execResult.stdout` 结构是 `[{text: "..."}]`，不是字符串数组。
- 坑 C：可用编译器 id（GET `https://godbolt.org/api/compilers/swift`，40 个）：
  `swift59`(5.9) / `swift510` / `swift603` / `swift61`~`swift642` / `arm-swift*`。
  与 `project.yml` 的 `SWIFT_VERSION: "5.9"` 对齐用 `swift59`。

### 5. ★★ Linux/Godbolt 上没有 Combine，`@Published` 报 unknown attribute
- 现象：core 文件 typecheck 时报 `unknown attribute 'Published'` / `cannot find type 'ObservableObject'`。
- 解决：`tools/typecheck_shim.swift` 提供最小桩：
  ```swift
  public protocol ObservableObject: AnyObject {}
  @propertyWrapper public final class Published<Value> {
      public var wrappedValue: Value
      public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
      public init(initialValue: Value) { self.wrappedValue = initialValue }
  }
  ```
  拼接顺序必须**shim 在最前**，且逐行剥掉源码里的 `import Combine` / `import SwiftUI` / `import UIKit`。
- **shim 不参与 App 构建**，只在验证工具里用。

### 6. Godbolt 上没有 URLSession
- 现象：`SubscriptionFetcher.swift` typecheck 报 `cannot find type 'URLSession'`。
- 解决：文件顶部加
  ```swift
  #if canImport(FoundationNetworking)
  import FoundationNetworking
  #endif
  ```
  （Linux 上 URLSession 在独立模块 FoundationNetworking 里；iOS 上这个条件为 false，零影响。）

### 7. ★ Darwin / Glibc 三处差异
1. `sockaddr_in.ai_socktype` 在 Linux 上是 `__socket_type` 而不是 `Int32`
   → 加计算属性 `private static var sockStreamType: Int32 { #if canImport(Darwin) return Int32(SOCK_STREAM) #else return Int32(SOCK_STREAM.rawValue) #endif }`
2. `IPPROTO_TCP` 需要 `Int32(IPPROTO_TCP)` 显式包一层
3. **`FD_ZERO` / `FD_SET` 是 C 宏，Swift 导不进来**（`cannot find 'FD_ZERO' in scope`）
   → 整个 `select(2)` 超时方案换成 `poll(2)`：
   ```swift
   var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
   let r = poll(&pfd, 1, timeoutMs)
   ```

### 8. `curl -o 相对路径` 在 `cd` 未生效时失败
- 现象：`cd /e/clash/clashmgr/fixtures && curl -o x.yaml ...` 在子目录里报 `No such file or directory`。
- 解决：先 `cd` 到目标目录再写，或用绝对路径。
- 另：**本机 `curl` 不带代理参数会 000 超时**，必须 `-x http://127.0.0.1:7897` 或 `export HTTPS_PROXY=...`。

### 9. `/tmp/` 在本机 bash 里不存在
- 现象：脚本往 `/tmp/xxx` 写文件失败。
- 解决：所有中间产物落到项目内路径（如 `clashmgr/tools/`）。

### 10. `PYTHONIOENCODING=utf-8` 必带
- 现象：Windows 默认 GBK stdout，打印 Godbolt 返回的中文/Unicode 报错时 `UnicodeEncodeError`，掩盖真实错误。
- 解决：所有验证脚本调用前 `export PYTHONIOENCODING=utf-8`，脚本内也用 `sys.stdout.write` + `flush()`。

---

## 三、代码类（被验证工具抓出来的真 bug）

### 11. ★★ Swift 原始多行字符串必须「三个引号」
- 现象：拼 fixture 时生成 `###"..."###` 报 `error: unterminated string literal`。
- 原因：只写了 `'#'*3` + 单个 `"`。正确是**三个 `#` + 三个 `"`**：
  ```python
  delimiter = '#' * 3
  quotes = '"' * 3
  return delimiter + quotes + '\n' + text + '\n' + quotes + delimiter
  ```
- **踩了两次**，第二次是因为没把拼接逻辑抽成变量。

### 12. ★ 拼装源码时的分隔注释用了字面 `\n`
- 现象：`tools/typecheck.py` 里 `f'// ==== {rel} ====\\n'` 写成了字面反斜杠 n，
  导致下一文件的首行被注释掉，报莫名其妙的语法错误。
- 解决：改成分两次 `append`。

### 13. ★ `.topBarTrailing` 是 iOS 17+，target 16.0 编不过
- 报错：`'topBarTrailing' is only available in iOS 17.0 or newer`
- 解决：统一改 `.navigationBarTrailing`（iOS 16 安全）。
  `.cancellationAction` / `.confirmationAction` 是 iOS 14+，可以留。

### 14. ★ 视图不能写 `private(set)` 属性
- 现象：`SettingsView` 里 `state.latencyFailures.removeAll()` 报
  `cannot assign to property: 'latencyFailures' setter is inaccessible`。
- 解决：在 `AppState` 加公开方法 `clearLatencyResults()` 封装掉，视图只调方法。

### 15. SwiftUI 在 iOS 上会传递引入 UIKit，但不能指望
- `UIPasteboard` / `UIImage` / `UIViewControllerRepresentable` / `UIActivityViewController`
  在只 `import SwiftUI` 的文件里**通常**能编译，但显式 `import UIKit` 更稳。

### 16. `ForEach` 的三类坑
1. **tuple 不能用 keypath**：`ForEach(Array(skipped.enumerated()), id: \.offset)` 编不过。
   → 把 tuple 换成 `struct SkippedRule: Identifiable { var index: Int; var id: Int { index } }`。
2. `ForEach(Array(x.enumerated()), id: \.element.id)` 是合法写法（`element` 是 tuple 标签）。
3. `ForEach(x)` 不写 `id:` 要求元素 `Identifiable`——项目里 5 个模型都加了。

### 17. ★ 可选 init 在 View 里不好用
- 现象：`TrafficBar` 原来写 `init?(info:)`，视图里配 `if let` 写起来很别扭且容易类型推断失败。
- 解决：改成**非可失败 `init(info:)` + `static func isAvailable(_:) -> Bool`**，视图写 `if TrafficBar.isAvailable(info) { TrafficBar(info: info) }`。

### 18. ★ `stripComment` 把英文撇号当引号起点
- 现象：`it's a secrect # comment` 解析出的值带着 `# pre-shared secret...` 尾巴。
- 根因：plain scalar 中间的 `'` 被当成引号开始，导致后面 `#` 不再被识别为注释。
- 解决：只有引号位于 **token 起始位置**（前一个非空白字符属于 `:-,[{` 或没有）才进引号态。

### 19. ★ 序列项与父键同缩进是合法 YAML（`User-Agent:` 那种写法）
```yaml
header:
  User-Agent:
  - "clash.meta"
```
- 漏掉 `if ln.indent == ind && isSeqItem(ln) { return parseSeq(ind) }`，该键会解析成 `nil`。

### 20. 块标量 `|` 的结尾换行语义
- `|` clip：保留**恰好一个**结尾换行
- `|-` strip：去掉
- `|+` keep：保留全部
- 而且序列项里也可能出现 `- |`，`parseSeq` 要单独识别。

### 21. `findColon` 必须只在「冒号后是空白或行尾」时才算映射分隔
- 否则 `url: http://a` 会在 `http:` 处被切断。
- 同时要跳过引号内和 flow 结构（`[]`/`{}`）内部的冒号，用 depth 计数。

### 22. 空行归属导致多次往返膨胀
- 现象：`parseDocument` → `toText()` → 再 parse → 再 toText，文件越来越长。
- 根因：文件末尾的连续空行既没进最后一块也没进 prologue，每次都被重复生成。
- 解决：末尾连续空行从最后一块摘出，单独放 `epilogue`。

---

## 四、CI / 签名类

### 23. 免费账号装 App 的正确姿势
- CI 产出**未签名 ipa**（`xcodebuild archive` + `CODE_SIGNING_ALLOWED=NO` + 手动 zip 成 `Payload/`），
  再用 AltStore / SideStore / Sideloadly 在本机重签。
- 不要指望 CI 直接出可安装的签名包——那需要 `.p12` + `.mobileprovision`（付费账号才有稳定分发）。

### 24. 图标带 alpha 会被 App Store / Xcode 拒
- 现象：手写 PNG 时如果用 RGBA，1024 图标带 alpha。
- 解决：写 PNG 时用 `color type=2`（RGB，无 alpha 通道）。

---

## 五、待办 / 未验证

- **SwiftUI 视图层从未在真实 Xcode 下编译过**，只有 Godbolt `-parse` 语法检查。
  首次 CI 运行可能需要修 1–3 轮（`.onChange` 签名、`Form` 里的 `Picker` 泛型、`toolbar` 内容推断等常见点）。
- `E:\clash\clashmgr` 目前**不是 git 仓库**，本机无 `gh` CLI、无 `GITHUB_TOKEN`、无 SSH key、
  `git config user.name/email` 均为空 → 推 GitHub 需要用户提供凭据或在网页端建仓库。
