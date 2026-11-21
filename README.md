# ClashMgr（流量管家）— iOS 版 Mihomo 订阅管家

模仿 Android 端 **Clash Meta For Android (CMFA)** 的功能面，做一个 iOS App。
因为**没有付费 Apple Developer 账号**，iOS 系统级 VPN（`NEPacketTunnelProvider`）拿不到 entitlement，
所以本项目采用**方案 C**：不做隧道，只做 CMFA「除隧道之外的全部实用界面」，外加 CMFA 没有的能力
——把挑好的节点导出成 YAML 给电脑端 mihomo / Clash Verge 用。

- 纯 SwiftUI，iOS 16.0+，**无任何 entitlement / NetworkExtension**
- 纯本地，无后台常驻，无服务器
- 未签名 ipa 可交给 AltStore / SideSide 用免费 Apple ID 重签安装

---

## 1. 功能边界（核心五项）

| Tab | 能力 |
| --- | --- |
| **订阅** | 列表（名称 / 域名 / 更新时间 / `subscription-userinfo` 流量条与到期）、三种导入（URL / 贴 YAML / 文件）、刷新（带 ETag 304 协商）、重命名、删除、设为当前 |
| **代理** | 策略组（select / url-test / fallback / load-balance / relay）→ 组内节点；全部节点平铺，按协议 + 搜索筛选；延迟色块（绿 <200ms / 黄 <500ms / 红 / 灰未测）；单点测速 + 全量测速（并发可调 1–32） |
| **规则** | 规则列表（类型 / 内容 / 目标组）+ 搜索；**规则测试**：输入域名或 URL，显示命中规则行与最终走向（含 MATCH 兜底） |
| **设置** | 订阅 User-Agent、测速并发与超时、探测地址、默认刷新周期、清缓存、关于、导出入口 |

**明确不做**（用户 m00048 确认）：流量图表、二维码扫码、内置浏览器。

额外能力：`clashmgr://` URL Scheme（快捷指令触发 `refresh` / 切 Tab）。

---

## 2. 目录结构

```
clashmgr/
├─ .github/workflows/ios.yml      CI：build + test + 打包未签名 ipa
├─ ios/
│  ├─ project.yml                 XcodeGen 工程定义（不手写 pbxproj）
│  ├─ ClashMgr/
│  │  ├─ App/
│  │  │  ├─ ClashMgrApp.swift     @main，四 Tab，onOpenURL
│  │  │  └─ AppState.swift        全局状态（@MainActor）
│  │  ├─ Core/                    自研 YAML 引擎（4 文件）
│  │  │  ├─ YAMLValue.swift       YAMLValue 枚举 + 保序 YAMLMap
│  │  │  ├─ YAMLLexer.swift       行切分 / 去注释 / 找冒号 / 去引号
│  │  │  ├─ YAMLParser.swift      Document 分块 + 结构解析 + flow 解析
│  │  │  └─ YAMLEmitter.swift     标量转义 + 缩进发射
│  │  ├─ Models/
│  │  │  ├─ ProxyModels.swift     ProxyNode / ProxyGroup / Rule
│  │  │  ├─ MihomoConfig.swift    配置聚合 + 组递归解析
│  │  │  ├─ RuleMatcher.swift     规则匹配（复刻 mihomo 优先级）
│  │  │  └─ Subscription.swift    订阅元数据 + userinfo 解析
│  │  ├─ Services/
│  │  │  ├─ AppSettings.swift     UserDefaults 设置
│  │  │  ├─ ConfigStore.swift     本地文件存储（Documents/ClashMgr）
│  │  │  ├─ SubscriptionFetcher.swift  URLSession 拉取 + 头解析
│  │  │  ├─ LatencyTester.swift   TCP 握手 RTT（poll 超时）
│  │  │  └─ Exporter.swift        裁剪节点后重发射 YAML
│  │  ├─ Views/                   8 个 SwiftUI 视图
│  │  ├─ Support/Info.plist
│  │  └─ Resources/Assets.xcassets  图标 + 主题色（脚本生成）
│  └─ ClashMgrTests/              38 个 XCTest（YAMLTests + ModelTests）
├─ fixtures/mihomo-sample.yaml    144KB 真实 mihomo 官方配置（验证用）
└─ tools/                         本地验证工具链（不参与 App 构建）
   ├─ typecheck.py                Godbolt 做 Foundation-only 类型检查
   ├─ typecheck_tests.py          连同测试文件一起检查（含 XCTest）
   ├─ syntaxcheck.py              Godbolt -parse 做 SwiftUI 语法检查
   ├─ runcheck.py + runcheck_main.swift  Godbolt 真执行 60 项行为断言
   ├─ runtests.py                 Godbolt 上真跑 38 个 XCTest 用例
   ├─ make_assets.py              numpy 4x 超采样生成 App 图标
   ├─ apiaudit.py                 视图 → 服务层 API 交叉核对
   └─ ref/{yaml_lite.py,verify_yaml.py}  Python 同算法镜像（oracle）
```

---

## 3. 核心设计

### 3.1 两层 YAML 架构（本项目的关键决策）

最大风险是「自研 YAML」。解法是**两层分离**：

1. **文档层**：`YAMLDocument` 按顶层键切块，每块存 `headerRaw`（`key: ...` 整行）+ `block`（该键下所有原始行，含注释与缩进）。
   `toText()` 把 prologue + 每块原样拼回 → **字节级还原原文**。
2. **结构层**：`YAMLParser` 只解析需要读写的子树。

**为什么这样分**：导出时 `dns:` / `tun:` / `sniffer:` / `tunnels:` / 证书等段落**完全不经过发射器**，
零改坏风险；只有 `proxies` / `proxy-groups` / `rules` 走「解析 → 修改 → 重发射」。
发射器已被 PyYAML 双向验证语义等价。

### 3.2 验证策略（本机无 Swift 编译器的绕法）

Windows 上装不上 Swift 工具链（无 MSVC / 无 Windows SDK / 无 Docker / WSL 未装）。
于是用 **Godbolt Compiler Explorer 的 `swift59`** 做三层门禁：

| 门禁 | 命令 | 作用 |
| --- | --- | --- |
| 类型检查 | `python tools/typecheck.py` | 14 个 core/services 文件拼成单文件 `-typecheck`，输出 `TYPECHECK OK` |
| 语法检查 | `python tools/syntaxcheck.py` | 8 个 SwiftUI 文件 `-parse`（只查语法，不查 API），输出 `SYNTAX OK` |
| **行为验证** | `python tools/runcheck.py` | 编译成可执行程序**真跑**，60 项行为断言，输出 `RUNCHECK OK` |
| **测试验证** | `python tools/runtests.py` | 在 Godbolt 上真跑 38 个 XCTest 用例，输出 `RUNTESTS OK` |

`runtests.py` 是关键一步：Linux 版 swift-corelibs-xctest 可用，所以 CI 里 `xcodebuild test`
会跑的那批用例，可以先在本地全部跑绿，避免「测试代码本身写错」导致 CI 红。

行为验证的真值来自 PyYAML 独立解析同一个 144KB fixture 作 oracle。
`tools/ref/yaml_lite.py` 是与 Swift **完全同算法**的 Python 镜像，先在这里修完 7 个真实缺陷再转写 Swift。

**Godbolt 关键点**：
- 端点 `POST https://godbolt.org/api/compiler/swift59/compile`，必须走代理
- `filters: {"execute": True}` 才会真跑，响应里读 `execResult.stdout`
- 判成功必须用 `res['code']==0 and execResult is not None`（`buildResult` 不是总会返回）
- `typecheck_shim.swift` 提供 `ObservableObject` / `@Published` 桩（Linux 无 Combine）
- 拼装时逐行剥掉 `import Combine` / `import SwiftUI` / `import UIKit`

### 3.3 测速为什么是 TCP 握手

没有隧道就不能发 HTTP 请求过代理，所以测的是到节点 `server:port` 的 **TCP 握手 RTT**。
它不能代表真实吞吐，但足以判断「节点是否可达 / 哪个更快」。
实现用非阻塞 `connect` + `poll(2)` 超时（`FD_ZERO`/`FD_SET` 是 C 宏，Swift 导不进来）。

### 3.4 导出的裁剪规则

- `proxies` 按原顺序过滤，只留勾选的
- 每组 `members` 裁剪条件 = 勾选节点 ∪ 组名（组可以引用组）∪ 内置目标（`DIRECT` / `REJECT` / `PASS` / `COMPATIBLE`）
- 组被剪空 → 回填 `DIRECT`，避免 mihomo 启动报错
- **解析不出 name 的 proxy 条目原样保留**，避免静默丢数据
- `includeRules = false` 时整个 `rules` 块移除

---

## 4. 本地验证（Windows 上就能跑）

```bash
cd E:/clash/clashmgr
export HTTPS_PROXY=http://127.0.0.1:7897   # 代理必须开
export PYTHONIOENCODING=utf-8              # 否则中文断言信息在 GBK 控制台报错

python tools/typecheck.py        # → TYPECHECK OK（14 个核心文件）
python tools/typecheck_tests.py  # → TESTS TYPECHECK OK（含测试文件）
python tools/syntaxcheck.py      # → SYNTAX OK（8 个 SwiftUI 文件）
python tools/runcheck.py         # → checks=60 failures=0 / RUNCHECK OK
python tools/runtests.py         # → Executed 38 tests, 0 failures / RUNTESTS OK
python tools/make_assets.py      # 重新生成图标
```

Python oracle 单独验证：

```bash
cd tools/ref
PYTHONIOENCODING=utf-8 python verify_yaml.py   # 26 用例 + 39 顶层键深比对
```

---

## 5. CI / 打包

`.github/workflows/ios.yml` 两个 job：

1. **build-and-test**（`macos-14`）
   `brew install xcodegen` → `xcodegen generate` → `xcodebuild build` + `xcodebuild test`
   （模拟器用 `xcrun simctl list devices available` 现场挑第一个可用的 iPhone，取其 UDID 传
   `-destination "id=$SIM_UDID"`，避免 runner 镜像升级后 `name=iPhone 15` 找不到设备；
   编译参数带 `CODE_SIGNING_ALLOWED=NO`）
2. **package-unsigned-ipa**（依赖 1，仅 main / 手动触发）
   `xcodebuild archive` → `Payload/` → `zip` 成 **未签名 ipa** 作为 artifact

拿到未签名 ipa 后，用 **AltStore / SideStore / Sideloadly** 配免费 Apple ID 自签安装
（7 天到期需重签；本项目无 NetworkExtension，所以免费账号够用）。

**触发路径**：`ios/**`、`fixtures/**`、workflow 自身。

---

## 6. 与 CMFA 的功能对应

| CMFA | 本项目 | 说明 |
| --- | --- | --- |
| 主页启停 / 实时流量 | ✗ | 需要隧道 |
| Profiles 订阅管理 | ✓ | 三种导入 + ETag 协商刷新 |
| Proxies 策略组 | ✓ | 五种组类型 + 组递归 |
| 节点测速 | ✓ | TCP 握手 RTT（非隧道） |
| Rules 规则列表 | ✓ | 额外做了**规则测试** |
| Providers | 部分 | 只读展示，不做 provider 下载 |
| NetworkSettings / TunSettings | ✗ | 无隧道 |
| Logs / Logcat | ✗ | 无内核 |
| 配置导出 | ✓ **增强** | CMFA 只能导出整份配置；本项目可按节点裁剪 |
| 外部 URL Scheme 控制 | ✓ | `clashmgr://` |

---

## 7. 已知限制

- **不能科学上网**。这是方案 C 的固有限制，不是 bug。
- 测速只测 TCP 握手，不代表真实带宽。
- 规则测试对 `GEOIP` / `GEOSITE` / `RULE-SET` / `IP-ASN` / `SUB-RULE` / 逻辑规则（AND/OR/NOT）等
  需要规则库或网络上下文的类型返回「离线不可判定」，会跳过并继续匹配后续规则（与 mihomo 行为一致）。
- 本机无 macOS，**SwiftUI 视图层从未在真实 Xcode 下编译过**，只有 Godbolt 语法检查。
  首次 CI 运行可能需要修 1–3 轮。

---

## 8. 参考

- [CMFA（Clash Meta For Android）](https://github.com/MetaCubeX/ClashMetaForAndroid)
- [mihomo 官方配置文档](https://github.com/MetaCubeX/mihomo/blob/Meta/docs/config.yaml)（本项目 fixture 来源）
- [swihomo](https://github.com/ruattd/swihomo) — SwiftUI + Packet Tunnel 的 A 路线参考实现
