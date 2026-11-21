#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""GitHub OAuth 设备码登录（RFC 8628），拿到 token 后直接建仓+推送+轮询 Actions。

不建 PAT、不点设置页 —— 只需要在浏览器里输入一个 8 位码然后点 Authorize。

    export HTTPS_PROXY=http://127.0.0.1:7897
    cd /e/clash/clashmgr
    PYTHONIOENCODING=utf-8 python tools/gh_login.py --repo clashmgr

说明：这里复用 GitHub CLI 的**公开** OAuth App client_id，所以授权页上显示的应用名是
"GitHub CLI"。它只申请 `repo` 权限（读写你自己的仓库）。不想用的话就走 PAT：
`GITHUB_TOKEN=ghp_xxx python tools/push_github.py`。

token 只在内存里，用来 git push 一次，然后 remote 立刻改回不含 token 的地址；
不写任何文件、不进 git、不落日志。
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# GitHub CLI 的公开 client_id（OAuth App，支持 device flow）
CLIENT_ID = "178c6fc778ccc68e1d6a"
DEVICE_CODE_URL = "https://github.com/login/device/code"
TOKEN_URL = "https://github.com/login/oauth/access_token"

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def _opener():
    proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
    if proxy:
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": proxy, "https": proxy})
        )
    return urllib.request.build_opener()


def _post(url, fields):
    data = urllib.parse.urlencode(fields).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Accept", "application/json")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    req.add_header("User-Agent", "clashmgr-device-flow")
    try:
        with _opener().open(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        raise SystemExit("HTTP %s: %s" % (exc.code, body))


def request_device_code(scope):
    return _post(DEVICE_CODE_URL, {"client_id": CLIENT_ID, "scope": scope})


def poll_token(device_code, interval, expires_in):
    """按 interval 轮询，直到拿到 access_token 或过期。"""
    deadline = time.time() + expires_in
    wait = max(5, int(interval))
    while time.time() < deadline:
        time.sleep(wait)
        res = _post(TOKEN_URL, {
            "client_id": CLIENT_ID,
            "device_code": device_code,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        })
        if res.get("access_token"):
            return res["access_token"]
        err = res.get("error")
        if err == "authorization_pending":
            sys.stdout.write(".")
            sys.stdout.flush()
            continue
        if err == "slow_down":
            wait += 5
            continue
        if err == "expired_token":
            raise SystemExit("\n设备码已过期，请重新运行脚本。")
        if err == "access_denied":
            raise SystemExit("\n你在页面上点了拒绝，已取消。")
        raise SystemExit("\n未知错误：%s %s" % (err, res.get("error_description", "")))
    raise SystemExit("\n等待超时，请重新运行脚本。")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="clashmgr")
    ap.add_argument("--owner", default=None, help="默认用登录账号")
    ap.add_argument("--private", action="store_true", help="建私有仓库（默认公开）")
    ap.add_argument("--scope", default="repo workflow", help="默认 repo workflow（推送 .github/workflows/ 必须带 workflow）")
    ap.add_argument("--timeout-minutes", type=int, default=40)
    ap.add_argument("--skip-poll", action="store_true")
    args = ap.parse_args()

    print("正在向 GitHub 申请设备码 ...")
    dev = request_device_code(args.scope)
    if "device_code" not in dev:
        raise SystemExit("申请失败：%s" % json.dumps(dev, ensure_ascii=False))

    user_code = dev["user_code"]
    url = dev.get("verification_uri", "https://github.com/login/device")
    print()
    print("=" * 56)
    print("  1. 打开   %s" % url)
    print("  2. 输入码 %s" % user_code)
    print("  3. 点绿色的 Authorize 按钮")
    print("=" * 56)
    print()
    print("等待授权（无需回到终端，授权后会自动继续）", end="", flush=True)

    token = poll_token(dev["device_code"], dev.get("interval", 5), dev.get("expires_in", 900))
    print("\n授权成功，token 已获取（仅本次内存中使用）")

    # 把 token 交给 push_github.py：用子进程 + 环境变量，避免写盘
    env = dict(os.environ)
    env["GITHUB_TOKEN"] = token
    env["PYTHONIOENCODING"] = "utf-8"
    cmd = [sys.executable, os.path.join(REPO_ROOT, "tools", "push_github.py"),
           "--repo", args.repo]
    if args.private:
        cmd.append("--private")
    if args.owner:
        cmd += ["--owner", args.owner]
    if args.skip_poll:
        cmd.append("--skip-poll")
    else:
        cmd += ["--timeout-minutes", str(args.timeout_minutes)]

    print("调用 push_github.py ...\n")
    rc = subprocess.run(cmd, cwd=REPO_ROOT, env=env).returncode
    sys.exit(rc)


if __name__ == "__main__":
    main()
