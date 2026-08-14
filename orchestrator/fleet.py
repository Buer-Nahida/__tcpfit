#!/usr/bin/env python3
"""
fleet — 多服务器调优编排器（未上线）

*** 尚未在真实环境验证过, 暂时不建议使用. ***

把 tcpfit.sh 临时推到清单里的每台机器并发执行, 收集结果、生成对照报告.
临时脚本在命令结束时删除，不安装到目标机的 PATH.

用法:
  fleet.py detect                     并发采集所有机器画像
  fleet.py tune   [--only NAME,...]   生成基础调优配置
  fleet.py sweep                      实测各机限速拐点（耗时长）
  fleet.py shape  [--auto]            生成整形配置；--auto 用 sweep 结果
  fleet.py status                     查看当前状态
  fleet.py verify                     状态 + 吞吐验证
  fleet.py rollback                   回滚
  fleet.py run -- <任意命令>          在所有机器上执行

通用选项:
  -i/--inventory FILE   清单文件（默认 inventory/servers.yml）
  --only NAME,... 只操作指定机器
  --tag TAG             只操作带该标签的机器
  -j/--jobs N           并发数（默认 8）
  --dry-run             只打印将要执行的命令
"""

import argparse
import concurrent.futures as cf
import json
import os
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
AGENT = ROOT / "tcpfit.sh"
RESULTS = ROOT / "results"
DEFAULT_INVENTORY = ROOT / "inventory" / "servers.yml"
REMOTE_AGENT = f"/tmp/tcpfit-{os.getpid()}"

C = {"r": "\033[0;31m","g": "\033[0;32m","y": "\033[0;33m",
     "c": "\033[0;36m","b": "\033[1m","0": "\033[0m"}
if not sys.stdout.isatty():
    C = {k: "" for k in C}


def log(msg):
    print(f"{C['c']}[*]{C['0']} {msg}", flush=True)


def die(msg, code=1):
    print(f"{C['r']}[x]{C['0']} {msg}", file=sys.stderr)
    sys.exit(code)


# ── 清单 ────────────────────────────────────────────────────────────────────
class Host:
    """一台目标机. password 与 key 二选一；缺省走 ssh agent / 默认密钥."""

    def __init__(self, d):
        self.name = d["name"]
        self.host = d["host"]
        self.port = int(d.get("port", 22))
        self.user = d.get("user","root")
        self.password = d.get("password")
        self.key = d.get("key")
        self.tags = d.get("tags", []) or []
        # 调优参数
        self.role = d.get("role","mixed")          # proxy / bulk / mixed
        self.bandwidth = d.get("bandwidth")          # Mbps, 标称
        self.rtt = d.get("rtt")                      # ms, 留空则目标机自测
        self.peer = d.get("peer")                    # sweep 用的 iperf3 对端
        self.shape_rate = d.get("shape_rate")        # 已知拐点可直接写死

    def __repr__(self):
        return f"<Host {self.name} {self.user}@{self.host}:{self.port}>"

    def ssh_base(self):
        cmd = []
        if self.password:
            cmd += ["sshpass","-p", self.password]
        cmd += ["ssh","-o","StrictHostKeyChecking=no",
                "-o","UserKnownHostsFile=/dev/null",
                "-o","LogLevel=ERROR",
                "-o","ConnectTimeout=20",
                "-p", str(self.port)]
        if self.key:
            cmd += ["-i", os.path.expanduser(self.key)]
        cmd += [f"{self.user}@{self.host}"]
        return cmd

    def scp_to(self, local, remote):
        cmd = []
        if self.password:
            cmd += ["sshpass","-p", self.password]
        cmd += ["scp","-o","StrictHostKeyChecking=no",
                "-o","UserKnownHostsFile=/dev/null",
                "-o","LogLevel=ERROR","-P", str(self.port)]
        if self.key:
            cmd += ["-i", os.path.expanduser(self.key)]
        cmd += [str(local), f"{self.user}@{self.host}:{remote}"]
        return cmd


def load_inventory(path, only=None, tag=None):
    p = Path(path)
    if not p.exists():
        die(f"清单不存在: {p}\n  先复制模板: cp {ROOT}/inventory/servers.example.yml {p}")
    data = yaml.safe_load(p.read_text()) or {}
    servers = data.get("servers") or []
    if not servers:
        die(f"清单里没有 servers: {p}")
    defaults = data.get("defaults") or {}
    hosts = []
    for s in servers:
        merged = {**defaults, **s}
        hosts.append(Host(merged))
    if only:
        want = {n.strip() for n in only.split(",")}
        hosts = [h for h in hosts if h.name in want]
        missing = want - {h.name for h in hosts}
        if missing:
            die(f"清单里找不到: {','.join(sorted(missing))}")
    if tag:
        hosts = [h for h in hosts if tag in h.tags]
    if not hosts:
        die("过滤后没有目标机器")
    return hosts


# ── 执行 ────────────────────────────────────────────────────────────────────
class Result:
    def __init__(self, host, rc, out, err, secs):
        self.host, self.rc, self.out, self.err, self.secs = host, rc, out, err, secs

    @property
    def ok(self):
        return self.rc == 0


def run_remote(h, command, timeout=1800, dry=False):
    cmd = h.ssh_base() + [command]
    if dry:
        print(f"  {C['y']}[dry]{C['0']} {h.name}: {' '.join(shlex.quote(c) for c in cmd[-1:])}")
        return Result(h, 0,"(dry-run)","", 0.0)
    t0 = time.time()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return Result(h, p.returncode, p.stdout, p.stderr, time.time() - t0)
    except subprocess.TimeoutExpired:
        return Result(h, 124,"", f"超时 ({timeout}s)", time.time() - t0)
    except FileNotFoundError as e:
        return Result(h, 127,"", f"本地缺少命令: {e}", 0.0)


def push_agent(h, dry=False):
    """把 agent 暂存到目标机 /tmp 并赋可执行权限."""
    if dry:
        print(f"  {C['y']}[dry]{C['0']} {h.name}: scp agent → {REMOTE_AGENT}")
        return True
    p = subprocess.run(h.scp_to(AGENT, REMOTE_AGENT), capture_output=True, text=True, timeout=120)
    if p.returncode != 0:
        return False
    r = run_remote(h, f"chmod +x {REMOTE_AGENT}", timeout=60)
    return r.ok


def fan_out(hosts, fn, jobs=8):
    out = []
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        futs = {ex.submit(fn, h): h for h in hosts}
        for f in cf.as_completed(futs):
            out.append(f.result())
    return sorted(out, key=lambda r: r.host.name)


def report(results, title):
    print()
    print(f"{C['b']}══ {title} ══{C['0']}")
    okc = sum(1 for r in results if r.ok)
    for r in results:
        mark = f"{C['g']}✓{C['0']}" if r.ok else f"{C['r']}✗{C['0']}"
        print(f"\n{mark} {C['b']}{r.host.name}{C['0']}  ({r.host.host})  {r.secs:.1f}s")
        body = (r.out or "").rstrip()
        if body:
            print("\n".join("    " + l for l in body.splitlines()))
        if not r.ok and r.err.strip():
            print("\n".join(f"    {C['r']}{l}{C['0']}" for l in r.err.strip().splitlines()[:8]))
    print(f"\n{C['b']}小结{C['0']}: {okc}/{len(results)} 成功")
    return okc == len(results)


def archive(results, action):
    RESULTS.mkdir(exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = RESULTS / f"{stamp}-{action}.json"
    path.write_text(json.dumps([{
        "name": r.host.name,"host": r.host.host,"rc": r.rc,
        "seconds": round(r.secs, 1),"stdout": r.out,"stderr": r.err,
    } for r in results], ensure_ascii=False, indent=2))
    log(f"结果已存档: {path.relative_to(ROOT)}")


# ── 子命令 ──────────────────────────────────────────────────────────────────
def agent_cmd(h, sub, args):
    """拼出目标机上要跑的 agent 命令."""
    parts = [REMOTE_AGENT, sub]
    if sub == "tune":
        parts += ["--role", h.role]
        if h.bandwidth:
            parts += ["--bw", str(h.bandwidth)]
        if h.rtt:
            parts += ["--rtt", str(h.rtt)]
    elif sub == "sweep":
        if not h.peer:
            return None
        parts += ["--peer", h.peer]
        if h.bandwidth:
            parts += ["--nominal", str(h.bandwidth)]
        if args.step:
            parts += ["--step", str(args.step)]
    elif sub == "shape":
        rate = h.shape_rate
        if args.auto:
            # 用目标机上 sweep 存下的推荐值
            return (f"RESULT_DIR=${{TCPFIT_DIR:-$HOME/tcpfit}}; "
                    f"[ -f \"$RESULT_DIR/sweep.result\" ] && "
                    f". \"$RESULT_DIR/sweep.result\" && "
                    f"{REMOTE_AGENT} shape --rate $RECOMMEND || "
                    f"{{ echo '没有 sweep 结果, 先跑 fleet.py sweep'; exit 1; }}")
        if not rate:
            return None
        parts += ["--rate", str(rate)]
    elif sub == "verify":
        if h.peer:
            parts += ["--peer", h.peer]
    return " ".join(shlex.quote(p) for p in parts)


def do_agent_action(hosts, sub, args):
    def work(h):
        if not push_agent(h, args.dry_run):
            return Result(h, 1,"","推送 agent 失败（检查 ssh 连通性/凭据）", 0.0)
        cmd = agent_cmd(h, sub, args)
        if cmd is None:
            if not args.dry_run:
                run_remote(h, f"rm -f -- {shlex.quote(REMOTE_AGENT)}", timeout=60)
            miss = "peer" if sub == "sweep" else "shape_rate"
            return Result(h, 1,"", f"清单里缺少 {miss}, 跳过", 0.0)
        cleanup = f"trap 'rm -f -- {shlex.quote(REMOTE_AGENT)}' EXIT; "
        return run_remote(h, cleanup + cmd, timeout=args.timeout, dry=args.dry_run)

    results = fan_out(hosts, work, args.jobs)
    allok = report(results, f"tcpfit {sub}")
    if not args.dry_run:
        archive(results, sub)
    return 0 if allok else 1


def do_run(hosts, args):
    if not args.command:
        die("run 需要命令：fleet.py run -- uptime")
    cmd = " ".join(args.command)
    results = fan_out(hosts, lambda h: run_remote(h, cmd, timeout=args.timeout, dry=args.dry_run), args.jobs)
    allok = report(results, f"run: {cmd}")
    return 0 if allok else 1


def main():
    ap = argparse.ArgumentParser(
        prog="fleet.py", description="多服务器 TCP 调优编排",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("action", choices=["detect","tune","sweep","shape",
                                       "status","verify","rollback","run"])
    ap.add_argument("command", nargs="*", help="run 用：要执行的命令")
    ap.add_argument("-i","--inventory", default=str(DEFAULT_INVENTORY))
    ap.add_argument("--only", help="只操作这些机器, 逗号分隔")
    ap.add_argument("--tag", help="只操作带该标签的机器")
    ap.add_argument("-j","--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=1800, help="单机超时秒数（sweep 需要调大）")
    ap.add_argument("--step", type=int, help="sweep 步长 Mbit")
    ap.add_argument("--auto", action="store_true", help="shape 用 sweep 的推荐值")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not AGENT.exists():
        die(f"找不到 agent: {AGENT}")

    hosts = load_inventory(args.inventory, args.only, args.tag)
    log(f"目标 {len(hosts)} 台: {','.join(h.name for h in hosts)}")

    if args.action == "run":
        sys.exit(do_run(hosts, args))
    # sweep 很慢, 默认给足超时
    if args.action == "sweep" and args.timeout == 1800:
        args.timeout = 3600
    sys.exit(do_agent_action(hosts, args.action, args))


if __name__ == "__main__":
    main()
