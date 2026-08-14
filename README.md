# tcpfit

面向 NixOS 的 TCP 测量与调优建议工具。它保留原有的 Bash TUI、带宽探测和限速器拐点扫描，但不会自动修改任何系统设置。

所有结果默认保存到 `~/tcpfit`（可用 `TCPFIT_DIR` 覆盖）：

- `tcpfit.nix`：按机器规格推导出的 `boot.kernel.sysctl` 建议
- `tcpfit-shaper.nix`：扫描找到拐点后生成的 HTB + fq 整形建议
- `tcpfit-swap.nix`：可选的 swap 建议
- `facts`、`probe.result`、`sweep.result`、`verify.result`、`summary.txt`：原始测量结果与摘要

脚本不写 `/etc`，不创建或启用 systemd service，不加载内核模块，不持久化修改 qdisc，也不会创建 swap。

## 运行

在仓库目录中运行：

```bash
nix run .
```

这会打开交互式 TUI。菜单、自动选择测速对端、带宽探测和拐点扫描均保留。

`probe`、`sweep` 和一键分析中实际测速的部分，为保证 pacing 精度会临时替换网卡 qdisc，因此需要 root 或 `CAP_NET_ADMIN`；结束或中断时会尝试恢复原 qdisc。仅生成基础建议不需要 root。

```bash
nix run . -- tune --role proxy --bw 500
sudo nix run . -- sweep --peer <近处的iperf3服务器> --nominal 500
```

通过 `sudo` 运行时，结果仍会保存给原调用用户的 `~/tcpfit`。若需指定别处：

```bash
TCPFIT_DIR=/path/to/results nix run .
```

## TUI

```
1. 一键分析   Auto analysis (recommended)
2. 生成建议   Generate TCP proposal
3. 拐点测试   Policer sweep
4. swap 建议  Generate swap proposal
5. 查看状态   Status
6. 端口验证   Verify port capability
7. 撤销说明   Manual rollback guide
8. 更新说明   Nix flake update guide
```

菜单 1 会按原来的交互流程提问、测速并扫描限速器；区别是最后只写出建议文件，不会应用它们。菜单 3 在找到建议整形值后只询问是否保存 NixOS 模块。

## 手动应用建议

先审阅 `~/tcpfit` 下生成的 `.nix` 文件。把需要的模块复制到你的 NixOS 配置目录，然后在 `configuration.nix` 中手动导入：

```nix
{
  imports = [
    ./hardware-configuration.nix
    ./tcpfit.nix
    # 只有确认需要整形时才加入：
    # ./tcpfit-shaper.nix
    # 只有确认需要 swap 时才加入：
    # ./tcpfit-swap.nix
  ];
}
```

确认后由你自行执行：

```bash
sudo nixos-rebuild switch
```

要撤销配置，移除相应的 `imports` 项并再次执行 `sudo nixos-rebuild switch`。tcpfit 本身没有可回滚的系统改动。

## 更新

脚本不会自行下载或覆盖 Nix store 中的文件。在仓库目录中更新 flake 后重新运行：

```bash
nix flake update
nix run .
```

## 许可证

[MIT](LICENSE)
