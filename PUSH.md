# 推送到 GitHub 并跑 CI

本机已建好本地 git 仓库，工作区干净。**唯一缺口是没有 GitHub 凭据**。
下面三种方式任选一种，方式 A 最省事。

---

## 方式 A：设备码授权，Agent 全自动完成（推荐）

不需要建 PAT、不需要进设置页。执行：

```bash
cd /e/clash/clashmgr
export HTTPS_PROXY=http://127.0.0.1:7897
PYTHONIOENCODING=utf-8 python tools/gh_login.py --repo clashmgr
```

脚本会打出：
1. 打开 `https://github.com/login/device`
2. 输入 8 位码（形如 `XXXX-XXXX`）
3. 点绿色 **Authorize**（页面上显示 GitHub CLI，因为复用了它的公开 OAuth App ID；只申请 `repo` + `workflow`）

授权后全自动：建仓 `leolong365/clashmgr` → push main → 轮询 Actions →
失败时打印失败 job 与 step。token 只在内存里用一次，不写盘。

> 也可以直接给 Agent 一个 PAT（https://github.com/settings/tokens/new ，classic，勾 repo+workflow），
> 然后 `GITHUB_TOKEN=ghp_xxx python tools/push_github.py --repo clashmgr`。

---

## 方式 B：你自己在网页建仓，再用一行命令推

1. 在 https://github.com/new 建空仓库（**不要**勾 README / .gitignore，避免冲突）
2. 在本机执行：

```bash
cd /e/clash/clashmgr
git remote add origin https://github.com/<你的用户名>/clashmgr.git
git push -u origin main
# 提示输入用户名时填 GitHub 用户名，密码处粘贴 PAT
```

3. 推送成功后 Actions 自动开跑：`https://github.com/<你的用户名>/clashmgr/actions`

---

## 方式 C：不用 git，网页直接拖文件

1. 新建空仓库后点 **uploading an existing file**
2. 把 `E:\clash\clashmgr` 下这些一起拖进去（保持目录层级）：
   - `.github/`
   - `ios/`
   - `fixtures/`
   - `README.md`、`bug.md`、`.gitignore`
3. **不要**拖 `tools/`（那是本地验证脚本，CI 用不到，但拖了也没事）
4. commit 到 `main` → Actions 自动触发

> 注意：浏览器拖拽无法上传以 `.` 开头的隐藏目录（`.github`），
> 如果拖不上去，就得用方式 A/B。

---

## 推送后会发生什么

`.github/workflows/ios.yml` 两个 job：

| job | 内容 | 失败时怎么办 |
| --- | --- | --- |
| `build-and-test` | `brew install xcodegen` → `xcodegen generate` → `xcodebuild build` + `xcodebuild test`（模拟器现场挑 UDID） | 下载 artifact **build-logs**（`ios/build.log` + `ios/test.log`），把日志发我 |
| `package-unsigned-ipa` | `xcodebuild archive` → `Payload/` → zip 成未签名 ipa | 同上 |

**预期**：SwiftUI 视图层从没在真 Xcode 下编译过，首次大概率要修 1–3 轮。
本地已经通过了 4 道门禁（`typecheck` / `syntaxcheck` / `typecheck_tests` / `runtests` 38 用例全绿 + `runcheck` 60 项行为断言），
所以问题基本只会出在 **SwiftUI/UIKit 的具体 API 签名** 上，逻辑层是干净的。

---

## 拿到 IPA 之后

`package-unsigned-ipa` 的 artifact `ClashMgr-unsigned-ipa` 里是
`ClashMgr-unsigned.ipa`（未签名）。

用 **AltStore / SideStore / Sideloadly** 配**免费 Apple ID** 自签安装：

- 7 天后过期需重新签名
- 免费账号同时最多 3 个自签 App
- 本项目**没有** NetworkExtension / entitlement，所以免费账号完全够用

安装后能做的事：管理订阅、看策略组、测延迟、查规则、导出 YAML 给电脑端用。
**不能**做的事：在本机科学上网（iOS 系统 VPN 需要付费账号的
`NEPacketTunnelProvider` entitlement，这是方案 C 的固有限制，见 `bug.md` 第 1 条）。
