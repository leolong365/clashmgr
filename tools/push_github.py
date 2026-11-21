#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""建仓 + 推送 + 轮询 GitHub Actions。

用法（PAT 从环境变量读，不落盘、不进 git）：

    export HTTPS_PROXY=http://127.0.0.1:7897
    export GITHUB_TOKEN=ghp_xxx
    cd /e/clash/clashmgr
    PYTHONIOENCODING=utf-8 python tools/push_github.py --repo clashmgr --private

做三件事：
  1. POST /user/repos 建仓（已存在则跳过）
  2. git remote add/set-url + git push -u origin main
  3. 轮询 /repos/{owner}/{repo}/actions/runs，直到结束；失败则打印失败 job 与日志下载地址

仅依赖标准库 + 本机 git。不会把 token 写进任何文件。
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def token():
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not tok:
        sys.stderr.write("缺少 GITHUB_TOKEN 环境变量\n")
        sys.exit(2)
    return tok.strip()


def api(path, tok, method="GET", payload=None, want_headers=False):
    url = path if path.startswith("http") else API + path
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + tok)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "clashmgr-push")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    opener = urllib.request.build_opener()
    proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
    if proxy:
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": proxy, "https": proxy})
        )

    def shape(code, body, headers):
        try:
            parsed = json.loads(body) if body.strip() else {}
        except ValueError:
            parsed = {"raw": body}
        return (code, parsed, headers) if want_headers else (code, parsed)

    try:
        with opener.open(req, timeout=60) as resp:
            body = resp.read().decode("utf-8", "replace")
            return shape(resp.status, body, dict(resp.headers))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        return shape(exc.code, body, dict(exc.headers or {}))



def git(*args, **kwargs):
    cmd = ["git"] + list(args)
    print("  $ " + " ".join(cmd))
    return subprocess.run(cmd, cwd=REPO_ROOT, text=True,
                          capture_output=True, **kwargs)


def ensure_repo(owner, repo, tok, private):
    status, data = api("/repos/%s/%s" % (owner, repo), tok)
    if status == 200:
        print("[1/3] 仓库已存在：%s" % data.get("html_url"))
        return data["html_url"], data["default_branch"]

    print("[1/3] 创建仓库 %s/%s ..." % (owner, repo))
    status, data = api("/user/repos", tok, "POST", {
        "name": repo,
        "private": bool(private),
        "description": "Mihomo 订阅管家 — iOS App（SwiftUI，仿 CMFA 功能面，无隧道）",
        "has_issues": True,
        "has_wiki": False,
        "auto_init": False,
    })
    if status not in (200, 201):
        sys.stderr.write("建仓失败 HTTP %s\n%s\n" % (status, json.dumps(data, ensure_ascii=False, indent=2)))
        sys.exit(1)
    print("      完成：%s" % data["html_url"])
    return data["html_url"], data.get("default_branch") or "main"


def push(owner, repo, tok):
    print("[2/3] 推送 main ...")
    remote = "https://x-access-token:%s@github.com/%s/%s.git" % (tok, owner, repo)
    public_remote = "https://github.com/%s/%s.git" % (owner, repo)

    # 分支名统一成 main
    head = git("rev-parse", "--abbrev-ref", "HEAD")
    branch = head.stdout.strip() if head.returncode == 0 else "main"
    if branch != "main":
        git("branch", "-M", "main")

    git("remote", "remove", "origin")
    r = git("remote", "add", "origin", remote)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        sys.exit(1)

    r = git("push", "-u", "origin", "main", "--force")
    if r.returncode != 0:
        # 避免 token 出现在报错里
        err = (r.stderr or "") + (r.stdout or "")
        err = err.replace(tok, "***")
        sys.stderr.write(err)
        sys.exit(1)

    # 推完立刻把 remote 换成不含 token 的地址
    git("remote", "set-url", "origin", public_remote)
    print("      推送成功（remote 已改回 %s）" % public_remote)


def poll(owner, repo, tok, timeout_minutes):
    print("[3/3] 轮询 Actions ...")
    deadline = time.time() + timeout_minutes * 60
    run = None
    while time.time() < deadline:
        status, data = api("/repos/%s/%s/actions/runs?per_page=5" % (owner, repo), tok)
        if status == 200:
            runs = data.get("workflow_runs") or []
            if runs:
                run = runs[0]
                state = run.get("status")
                print("      run #%s  状态=%s  结论=%s" % (
                    run.get("run_number"), state, run.get("conclusion")))
                if state == "completed":
                    break
        else:
            print("      查询失败 HTTP %s" % status)
        time.sleep(20)

    if not run:
        sys.stderr.write("没等到 workflow run\n")
        return 1

    if run.get("status") != "completed":
        sys.stderr.write("超时，run 仍未结束：%s\n" % run.get("html_url"))
        return 1

    conclusion = run.get("conclusion")
    print("\n运行页：%s" % run.get("html_url"))
    if conclusion == "success":
        print("\n*** BUILD & TEST 通过 ***")
        status, arts = api("/repos/%s/%s/actions/runs/%s/artifacts" % (owner, repo, run["id"]), tok)
        if status == 200:
            for a in arts.get("artifacts") or []:
                print("  artifact: %-28s %8s bytes  过期 %s" % (
                    a["name"], a["size_in_bytes"], a.get("expires_at")))
                print("            下载 %s" % a["archive_download_url"])
        return 0

    print("\n*** 失败：conclusion=%s ***" % conclusion)
    status, jobs = api("/repos/%s/%s/actions/runs/%s/jobs" % (owner, repo, run["id"]), tok)
    if status == 200:
        for job in jobs.get("jobs") or []:
            print("\n  job: %s  (%s)" % (job["name"], job.get("conclusion")))
            for step in job.get("steps") or []:
                if step.get("conclusion") != "success":
                    print("    step: %-40s %s" % (step["name"], step.get("conclusion")))
    return 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--owner", default="leolong365")
    ap.add_argument("--repo", default="clashmgr")
    ap.add_argument("--private", action="store_true")
    ap.add_argument("--timeout-minutes", type=int, default=40)
    ap.add_argument("--skip-poll", action="store_true")
    args = ap.parse_args()

    tok = token()
    status, me, headers = api("/user", tok, want_headers=True)
    if status != 200:
        sys.stderr.write("token 无效 HTTP %s\n%s\n" % (status, json.dumps(me, ensure_ascii=False)))
        sys.exit(2)
    scopes = headers.get("X-OAuth-Scopes") or headers.get("x-oauth-scopes") or ""
    owner = me.get("login") or args.owner
    print("已认证为 %s（scopes: %s）" % (owner, scopes or "fine-grained / 未声明"))
    if owner.lower() != args.owner.lower():
        print("注意：token 属于 %s，与 --owner %s 不一致，改用 %s" % (owner, args.owner, owner))

    html_url, _ = ensure_repo(owner, args.repo, tok, args.private)
    push(owner, args.repo, tok)
    if args.skip_poll:
        print("\n已跳过轮询。运行页：%s/actions" % html_url)
        return 0
    return poll(owner, args.repo, tok, args.timeout_minutes)


if __name__ == "__main__":
    sys.exit(main())
