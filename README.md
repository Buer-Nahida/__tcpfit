# tcpfit

按每台机器实测推导的 TCP 调优工具. 不套用固定参数, 实测 BDP 与限速器拐点.

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh)
```

跑完直接出菜单, 选 1 全自动. 脚本会装到 `/usr/local/bin/tcpfit`, 以后敲 `tcpfit` 即可.

固定版本并校验:

```bash
V=v0.3.6
curl -fsSLO https://github.com/Kylin010/tcpfit/releases/download/$V/tcpfit.sh &&
curl -fsSLO https://github.com/Kylin010/tcpfit/releases/download/$V/install.sh &&
curl -fsSLO https://github.com/Kylin010/tcpfit/releases/download/$V/SHA256SUMS &&
sha256sum -c SHA256SUMS &&
bash tcpfit.sh
```

## 三种用法

| 用法 | 命令 |
|---|---|
| 一键跑 | `bash <(curl -fsSL .../main/tcpfit.sh)` |
| 装好后 | `tcpfit` |
| 子命令 | `tcpfit tune --role proxy --bw 500` |

## 菜单

```
   1. 一键调优   Auto-tune (recommended)  ~10 min
   2. 基础调优   Base tuning only          ~1 min
   3. 拐点测试   Policer sweep             ~8 min
   4. 加 swap    Add swap (low-memory box)
   ────────────────────────────────────────────
   5. 查看状态   Status
   6. 端口验证   Verify port capability    ~1 min
   7. 回滚改动   Rollback all changes
   8. 检查更新   Check for updates
```

脚本不会自动更新. 装好之后跑的一直是装的那一版, 想升级用菜单 8 或 `tcpfit update` ——
它只检查, 发现新版本会问你要不要更新.

一键调优只问三个问题: 带宽、测速对端、机器用途. 确认之后跑到底不再打断.

带宽那一问支持四种输入:

| 输入 | 行为 |
|---|---|
| 数字 | 按该带宽推导缓冲区, 然后实测拐点 |
| 回车 | 现场实测带宽, 然后实测拐点 |
| `m` | 直接填限速值, 跳过拐点扫描 |
| `0` | 不做整形 |

## 子命令

```bash
tcpfit detect                                     # 机器画像
tcpfit probe    --peer <近处iperf3服务器>          # 探测可用带宽
tcpfit tune     --role proxy --bw 500             # 基础调优
tcpfit sweep    --peer <近处iperf3服务器> --nominal 500
tcpfit shape    --rate 510                        # 应用整形
tcpfit shape    --off                             # 移除整形, 保留基础调优
tcpfit harden   --swap 2G                         # 加 swap
tcpfit verify   --peer <近处iperf3服务器>          # 测速验证
tcpfit status                                     # 当前配置
tcpfit rollback                                   # 回滚全部改动
tcpfit update                                     # 检查更新
```

## 多机（未上线）

多机编排还没在真实环境验证过, 暂时不建议使用. 下面的用法仅供参考.


```bash
cp inventory/servers.example.yml inventory/servers.yml
chmod 600 inventory/servers.yml
vi inventory/servers.yml

python3 orchestrator/fleet.py detect
python3 orchestrator/fleet.py tune
python3 orchestrator/fleet.py sweep
python3 orchestrator/fleet.py shape --auto
python3 orchestrator/fleet.py verify
```

选项: `--only 机器名` `--tag 标签` `-j 并发数` `--dry-run`.
临时执行任意命令: `fleet.py run -- uptime`.

## 它改了什么

| 类别 | 参数 |
|---|---|
| 拥塞控制 | `tcp_congestion_control=bbr` + `default_qdisc=fq` |
| 缓冲区 | `tcp_rmem` / `tcp_wmem` / `rmem_max` / `wmem_max` / `tcp_mem` |
| 窗口 | `tcp_window_scaling` / `tcp_moderate_rcvbuf` / `tcp_adv_win_scale` |
| 队列 | `netdev_max_backlog` / `netdev_budget` / `somaxconn` 等 |
| 连接 | `tcp_tw_reuse` / `tcp_fin_timeout` / `ip_local_port_range` 等 |
| 起步 | `tcp_slow_start_after_idle=0` / `initcwnd 32` |
| 出向整形 | HTB 全局上限 + fq 叶子 pacing |

共 32 个 sysctl 参数. 缓冲区和整形值按每台机器实测推导, 不是固定值.

## 回滚

```bash
tcpfit rollback                # 按快照逐项写回, 不是恢复默认
tcpfit rollback --purge-swap   # 同时删掉 harden 建的 /swapfile
tcpfit shape --off    # 只去掉整形
```

首次改动前自动存快照到 `/var/lib/tcpfit/pre-tune.snapshot`, 记录全部 32 项参数的原始值.

swap 默认不动 —— 删掉正在用的 swap 可能让机器立刻 OOM, 要一并撤销得显式加 `--purge-swap`.

改动只落在这些文件, 不碰 `/etc/sysctl.conf`:

```
/etc/sysctl.d/99-tcpfit.conf
/etc/systemd/system/tcpfit-qdisc.service
/usr/local/sbin/tcpfit-qdisc.sh
/etc/networkd-dispatcher/routable.d/50-tcpfit-initcwnd
/etc/modules-load.d/tcpfit-bbr.conf
/var/lib/tcpfit/
```

用了 `harden --swap` 还会创建 `/swapfile` 并往 `/etc/fstab` 加一行 —— 这两个 `rollback` 默认不动,
要一并撤销加 `--purge-swap`. 缺 iperf3 时经你确认后会用包管理器安装它.

## 已知限制

- 瓶颈在国际链路而非端口时, 整形不会带来提升, 但输出看起来一切正常
- 扫满区间没找到拐点时会把区间上界当成拐点, 这种情况用 `m` 手动指定
- 需要 Linux + systemd + iproute2. OpenVZ/LXC 上 `tc` 和 `initcwnd` 可能受限
- `sweep` 需要一台近处的 iperf3 对端

## 从 nettune 升级

老机器上的产物文件名还是 `nettune-*`, 新版本会自动检测并搬迁, 快照和 rollback 都保留. 直接跑新版即可.

## 许可证

[MIT](LICENSE)
