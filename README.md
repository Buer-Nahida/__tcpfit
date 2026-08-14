# tcpfit

面向 NixOS 的 TCP 测量与调优建议工具。它保留原版 Bash TUI、带宽探测、公共对端选择和限速器拐点扫描；参数仍由同一组机器规格与实测结果推导，但最终只生成 NixOS 配置，不自动应用。

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Buer-Nahida/__tcpfit/main/tcpfit.sh)
```

脚本不会安装到 `/usr/local`，不通过 Nix runner 启动，也没有安装器或自更新流程。每次执行上面的命令都会直接运行仓库中的最新脚本并打开原有 TUI。

一键分析中的带宽探测和拐点扫描为保持原版 pacing 与计算结果，会在测试期间临时切换网卡 qdisc，并在正常结束或收到中断信号时恢复，因此这些测量沿用原版约束，需要以 root 运行。生成基础配置本身不需要 root。

缺少 `iperf3` 或 `ping` 时，脚本不会替你安装软件；请把 `pkgs.iperf3`、`pkgs.iputils` 加入自己的 NixOS 配置后重建。缺少 `iperf3` 仍可手动填写带宽并生成基础建议。

## 输出

所有结果默认保存在 `~/tcpfit`；通过 `sudo` 运行时会优先使用原调用用户的家目录。可用 `TCPFIT_DIR` 覆盖结果目录。

- `tcpfit.nix`：基础 TCP、BBR/cubic 与可选 initcwnd 配置
- `tcpfit-shaper.nix`：扫描找到拐点后生成的 HTB + fq 整形配置
- `tcpfit-swap.nix`：低内存机器的可选 swap 配置
- `facts`、`*.result`、`summary.txt`：机器画像、测量结果和摘要

脚本不会写 `/etc`、`/usr/local` 或 `/var/lib`，不会运行 `sysctl -w/-p`、加载内核模块、启用 systemd 服务、持久修改 qdisc、创建 swap 或执行 `nixos-rebuild`。

## TUI

```text
1. 一键分析   Auto analysis (recommended)
2. 生成建议   Generate TCP proposal
3. 拐点测试   Policer sweep
4. swap 建议  Generate swap proposal
5. 查看状态   Status
6. 端口验证   Verify port capability
7. 撤销说明   Manual rollback guide
8. 更新说明   Bash one-click update guide
```

菜单 1 仍按原流程询问带宽、测速对端和机器用途，然后执行同样的探测及拐点算法。区别只在收尾：它写出建议文件，不把建议持久应用到当前系统。

也可以在一键命令后直接加原有子命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Buer-Nahida/__tcpfit/main/tcpfit.sh) tune --role proxy --bw 500
bash <(curl -fsSL https://raw.githubusercontent.com/Buer-Nahida/__tcpfit/main/tcpfit.sh) sweep --peer <近处的iperf3服务器> --nominal 500
bash <(curl -fsSL https://raw.githubusercontent.com/Buer-Nahida/__tcpfit/main/tcpfit.sh) shape --rate 510
```

## 手动应用

先审阅 `~/tcpfit` 下生成的 `.nix` 文件，把需要的文件复制到 NixOS 配置目录，再手动导入：

```nix
{
  imports = [
    ./hardware-configuration.nix
    ./tcpfit.nix
    # 扫描确实给出整形建议时再加入：
    # ./tcpfit-shaper.nix
    # 确实需要 swap 时再加入：
    # ./tcpfit-swap.nix
  ];
}
```

确认内容后由你自行执行：

```bash
sudo nixos-rebuild switch
```

要撤销配置，从 `imports` 中移除对应文件并再次重建。tcpfit 本身没有持久系统改动可回滚。若曾导入 swap 建议，移除配置会停用 swap，但不会自动删除 `/swapfile`；需要释放磁盘时，请先确认它已停用，再手动删除该文件。

## 拐点扫描

扫描逻辑保持原版不变：先做不限速测试；若丢包低则判断没有限速器，若丢包出现跳变则从实测送达量上方向上扫描，并按原安全余量生成推荐值。超过默认 2500 Mbit 扫描上限时不会猜测整形值。

## 许可证

[MIT](LICENSE)
