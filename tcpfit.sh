#!/usr/bin/env bash
# tcpfit — 单机 TCP 调优代理
#
# 纯 bash, 除 iperf3(仅 sweep 需要) 外无依赖, 可在任何最小化 VPS 上直接跑.
# 所有"该设多少"的判断都由实测或机器规格推导, 不使用抄来的固定值.
#
# 用法:
#   tcpfit.sh                               交互式菜单（不带参数即可, 推荐）
#   tcpfit.sh detect                        输出机器画像
#   tcpfit.sh probe  --peer HOST            探测可用带宽(虚拟网卡读不到标称值时用)
#   tcpfit.sh tune   [选项]                 应用基础调优
#   tcpfit.sh sweep  --peer HOST [选项]     实测限速器拐点
#   tcpfit.sh shape  --rate N | --off       应用/移除出向整形
#   tcpfit.sh harden --swap 2G              加 swap（小内存机防止进程被杀）
#   tcpfit.sh verify [--peer HOST]          验证当前状态
#   tcpfit.sh status                        显示当前配置
#   tcpfit.sh rollback                      回滚到调优前
#
# 退出码: 0 成功 / 1 参数或环境错误 / 2 实测失败

set -uo pipefail

VERSION="0.3.3"
STATE_DIR="/var/lib/tcpfit"
SYSCTL_FILE="/etc/sysctl.d/99-tcpfit.conf"
QDISC_SCRIPT="/usr/local/sbin/tcpfit-qdisc.sh"
QDISC_UNIT="/etc/systemd/system/tcpfit-qdisc.service"
ROUTE_HOOK="/etc/networkd-dispatcher/routable.d/50-tcpfit-initcwnd"
SNAPSHOT="$STATE_DIR/pre-tune.snapshot"
FACTS="$STATE_DIR/facts"

# ── 输出 ────────────────────────────────────────────────────────────────────
# 配色对齐 x-ui, 用户在同一台机器上看到的风格一致
if [ -t 1 ]; then
  green=$'\033[0;32m'; red=$'\033[0;31m'; yellow=$'\033[0;33m'
  blue=$'\033[0;36m';  bold=$'\033[1m';   plain=$'\033[0m'
else
  green=''; red=''; yellow=''; blue=''; bold=''; plain=''
fi
_c(){ [ -t 1 ] && printf '\033[%sm%s\033[0m' "$1" "$2" || printf '%s' "$2"; }
info(){ printf '%s %s\n' "$(_c '0;36' '[*]')" "$*"; }
ok(){   printf '%s %s\n' "$(_c '0;32' '[+]')" "$*"; }
warn(){ printf '%s %s\n' "$(_c '0;33' '[!]')" "$*" >&2; }
die(){  printf '%s %s\n' "$(_c '0;31' '[x]')" "$*" >&2; exit "${2:-1}"; }

# 按显示宽度对齐：CJK 占 2 列, printf 的 %-Ns 按字节算会错位.
# 不能依赖 awk 的多字节支持 —— mawk(Debian 默认) 没有, 会把 3 字节的中文算成 3 个字符.
# 这里直接按 UTF-8 前导字节判断：ASCII=1列, 2字节序列=1列, 3字节及以上=2列, 续字节=0列.
_dispw(){
  printf '%s' "$1" | LC_ALL=C od -An -tu1 2>/dev/null | awk '
    {for(i=1;i<=NF;i++){b=$i
       if(b<128)            n++          # ASCII
       else if(b<192)       continue     # 续字节, 不计宽
       else if(b<224)       n++          # 2 字节序列(拉丁扩展等)
       else if(b==226){ nx=$(i+1); if(nx==148||nx==149){ n++; i+=2; continue } n+=2 }
       else                 n+=2         # 3 字节及以上(CJK、全角符号)
    }} END{print n+0}'
}
kv(){ local w; w=$(_dispw "$1"); printf '  %s%*s %s\n' "$1" $(( 20 - w )) "" "$2"; }
# 把字符串按「显示宽度」补齐到 N 列, 供手工排表用
_pad(){  local w; w=$(_dispw "$1"); printf '%s%*s' "$1" $(( $2 - w )) ""; }
_rpad(){ local w; w=$(_dispw "$1"); printf '%*s%s' $(( $2 - w )) "" "$1"; }
# 「确认」和「结果」里的两列排版
_conf(){ printf '      %s %s\n' "$(_pad "$1" 14)" "$2"; }

need_root(){ [ "$(id -u)" = 0 ] || die "需要 root 权限"; }

# 转圈. 长操作(iperf3 一跑十几秒)不给反馈的话用户会以为卡死了.
# 非交互环境(管道/日志)不画, 避免把日志刷满控制字符.
SPIN_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
spin_wait(){   # spin_wait <pid> <描述>
  local pid="$1" msg="$2" i=0
  if [ ! -t 2 ]; then wait "$pid" 2>/dev/null; return $?; fi
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  \033[0;36m%s\033[0m %s' "${SPIN_FRAMES:$((i++%10)):1}" "$msg" >&2
    sleep 0.12
  done
  printf '\r\033[K' >&2
  wait "$pid" 2>/dev/null
}
# ── 流量计量 ──────────────────────────────────────────────────────────────
# 读网卡字节计数器. 比按速率估算准 —— 它把重传、协议开销、握手全算进去了.
TRAFFIC_RX0=""; TRAFFIC_TX0=""
traffic_mark(){
  local i; i=$(detect_iface)
  TRAFFIC_RX0=$(cat "/sys/class/net/$i/statistics/rx_bytes" 2>/dev/null || echo 0)
  TRAFFIC_TX0=$(cat "/sys/class/net/$i/statistics/tx_bytes" 2>/dev/null || echo 0)
}
traffic_report(){
  [ -n "$TRAFFIC_TX0" ] || return 0
  local i rx tx drx dtx; i=$(detect_iface)
  rx=$(cat "/sys/class/net/$i/statistics/rx_bytes" 2>/dev/null || echo 0)
  tx=$(cat "/sys/class/net/$i/statistics/tx_bytes" 2>/dev/null || echo 0)
  drx=$(( rx - TRAFFIC_RX0 )); dtx=$(( tx - TRAFFIC_TX0 ))
  [ "$drx" -lt 0 ] && drx=0; [ "$dtx" -lt 0 ] && dtx=0
  echo
  printf '  %s本次测试消耗流量%s\n' "$bold" "$plain"
  rule
  awk -v tx="$dtx" -v rx="$drx" '
    function h(b){ if(b>=1073741824) return sprintf("%.2f GB", b/1073741824); return sprintf("%.0f MB", b/1048576) }
    BEGIN{
      printf "  %-16s %s\n","出向 (上传)", h(tx)
      printf "  %-16s %s\n","入向 (下载)", h(rx)
      printf "  %-16s %s\n","双向合计", h(tx+rx)
    }'
  rule
}

rule(){ printf '  \033[2m%s\033[0m\n' "────────────────────────────────────────────────"; }
step(){ printf '\n  \033[1;36m▸ %s\033[0m\n' "$*"; }

# 用 bash <(curl ...) 一条命令跑时, $0 是临时 fd, 脚本一退出就没了.
# 这里把自己装到系统里, 以后想回滚/查状态还能找到.
PEER_PORT="${PEER_PORT:-5201}"   # 选定对端时确定的可用端口
WIZARD=0                         # 一键流程内为 1：子命令只输出执行日志, 收尾统一由 wizard 打印
# 装成不带扩展名的 tcpfit, 放 /usr/local/bin —— 用户敲 `tcpfit` 就能进菜单.
# 不用 /usr/local/sbin 是因为它不在普通用户的 PATH 里, 非 root 敲命令会「找不到命令」,
# 而不是看到「需要 root 权限」这个有用的提示.
SELF_PATH="/usr/local/bin/tcpfit"
LEGACY_SELF="/usr/local/sbin/tcpfit.sh"   # v0.3.1 及更早装在这里, 装新版时清掉
# 面向用户的提示一律用这个, 不能用 $0 ——
# bash <(curl ...) 跑时 $0 是 /dev/fd/63, 提示出来的命令用户根本没法执行
# 提示用户"下一步敲什么". 装好之后 tcpfit 在 PATH 里, 直接说命令名即可；
# 没装成（非 root / 没 curl）才退回完整路径. 绝不能用 $0 ——
# bash <(curl ...) 跑时 $0 是 /dev/fd/63, 提示出来的命令用户根本没法执行.
disp(){
  [ -x "$SELF_PATH" ] && { echo "tcpfit"; return; }
  case "$0" in /dev/fd/*|/proc/self/fd/*|bash|-bash) echo "$SELF_PATH" ;; *) echo "$0" ;; esac
}
# 装到系统里的那一份, 必须和「你刚跑的这一份」是同一个版本.
#
# 原先无条件拉 main：你按 v0.3.0 下载、校验、运行, 它转头把 main 装进
# /usr/local/sbin —— 之后每次敲 tcpfit.sh 跑的都是没校验过的代码,
# 固定版本的意义被完全抵消. （我自己踩过：推完新版去远端验证, 看到的还是旧菜单.)
#
# 为什么不能直接复制"正在运行的脚本"：bash <(curl ...) 时 $0 是 /dev/fd/63,
# 内容已被 bash 读走, 再 cat 只能读到 0 字节；curl | bash 时 $0 = bash, 根本不可读.
# 实测验证过这两种情况. 所以只能按版本号回拉, 并校验拉到的确实是同一版.
SELF_URL="https://raw.githubusercontent.com/Kylin010/tcpfit/v${VERSION}/tcpfit.sh"
self_install(){
  [ "$(id -u)" = 0 ] || return 0
  case "$0" in "$SELF_PATH") return 0 ;; esac      # 已经是装好的那份
  command -v curl >/dev/null || return 0
  curl -fsSL "$SELF_URL" -o "$SELF_PATH".tmp 2>/dev/null || return 0
  # 校验版本一致. 开发期 main 领先 tag 时这里会失败, 跳过安装也是对的.
  if [ -s "$SELF_PATH".tmp ] && head -1 "$SELF_PATH".tmp | grep -q '^#!' \
     && grep -q "^VERSION=\"$VERSION\"" "$SELF_PATH".tmp; then
    mv "$SELF_PATH".tmp "$SELF_PATH"; chmod +x "$SELF_PATH"
    rm -f "$LEGACY_SELF"                      # 清掉旧位置, 免得两份不同版本并存
    ok "Installed: run 'tcpfit' anytime"
  else
    rm -f "$SELF_PATH".tmp
  fi
}

# ── 从旧名字 nettune 迁移 ──────────────────────────────────────────────────
# 项目 v0.3.1 从 nettune 改名为 tcpfit. 老机器上所有产物的文件名都还是 nettune-*,
# 新脚本按新名字去找会一个都找不到 —— 最危险的是 take_snapshot 的保护：
# 它检查 $SYSCTL_FILE 是否存在, 改名后该变量指向新路径, 老文件在它眼里不存在,
# 于是把「已调优状态」当成出厂基线存进快照, rollback 从此永久错误且无任何报错.
# 所以必须先搬迁, 而不是假装老部署不存在.
migrate_legacy(){
  local old_state=/var/lib/nettune
  local old_sysctl=/etc/sysctl.d/99-nettune.conf
  local old_qdisc=/usr/local/sbin/nettune-qdisc.sh
  local old_unit=/etc/systemd/system/nettune-qdisc.service
  local old_hook=/etc/networkd-dispatcher/routable.d/50-nettune-initcwnd
  local old_mod=/etc/modules-load.d/nettune-bbr.conf
  local old_self=/usr/local/sbin/nettune.sh
  # 一个旧产物都没有 → 全新机器, 什么都不用做
  [ -e "$old_state" ] || [ -e "$old_sysctl" ] || [ -e "$old_unit" ] || return 0
  [ "$(id -u)" = 0 ] || return 0

  info "检测到旧版本(nettune)的部署, 正在迁移到新名字(tcpfit)…"
  local rate=""
  # 先把整形值抠出来, 后面用新名字重建；不能直接改文件名, unit 里的路径也要跟着变
  [ -f "$old_qdisc" ] && rate=$(grep -oE 'rate [0-9]+mbit' "$old_qdisc" | head -1 | grep -oE '[0-9]+')
  systemctl disable --now nettune-qdisc.service >/dev/null 2>&1
  rm -f "$old_unit" "$old_qdisc"; systemctl daemon-reload >/dev/null 2>&1

  [ -e "$old_state" ]  && { mkdir -p "$(dirname "$STATE_DIR")"; mv -n "$old_state" "$STATE_DIR" 2>/dev/null; rm -rf "$old_state"; }
  [ -f "$old_sysctl" ] && mv -f "$old_sysctl" "$SYSCTL_FILE"
  [ -f "$old_hook" ]   && mv -f "$old_hook" "$ROUTE_HOOK"
  [ -f "$old_mod" ]    && mv -f "$old_mod" /etc/modules-load.d/tcpfit-bbr.conf
  rm -f "$old_self" "$LEGACY_SELF"

  if [ -n "$rate" ]; then
    write_qdisc "$rate" "$(detect_iface)"
    systemctl restart tcpfit-qdisc.service 2>/dev/null || "$QDISC_SCRIPT" >/dev/null 2>&1
    ok "迁移完成, 整形 ${rate}Mbit 已用新名字重建"
  else
    ok "迁移完成"
  fi
  info "快照保留在 $SNAPSHOT, rollback 仍然可用."
}

# ── 环境检测 ────────────────────────────────────────────────────────────────
detect_iface(){ ip route show default 2>/dev/null | awk '{print $5; exit}'; }
detect_gw(){    ip route show default 2>/dev/null | awk '{print $3; exit}'; }

# 到国内的 RTT 中位数.
# 关键：不能用 223.5.5.5（阿里 DNS）—— 它是 anycast, 全球有节点,
# 在圣何塞的机器上实测只有 2.7ms, 而同机到腾讯/百度 DNS 是 157-164ms.
# 混进 anycast 目标会让 BDP 算小几十倍, 缓冲区完全不够.
# 下列目标已在美西机器上逐个验证为真·国内（124-164ms, 无 anycast 迹象）.
detect_rtt(){
  local targets="${NETTUNE_RTT_TARGETS:-119.29.29.29 180.76.76.76 202.96.128.86 1.2.4.8 101.226.4.6}"
  local vals=() t r
  for t in $targets; do
    r=$(ping -c 3 -q -W 2 "$t" 2>/dev/null | awk -F'/' '/rtt|round-trip/{printf "%.0f", $5}')
    [ -n "$r" ] && vals+=("$r")
  done
  [ ${#vals[@]} -eq 0 ] && { echo ""; return; }
  printf '%s\n' "${vals[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'
}

detect_ram_mb(){ awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo; }
detect_cores(){  nproc 2>/dev/null || echo 1; }

# 网卡标称速率. 虚拟网卡多半读不到, 返回空由调用方处理
detect_link_mbps(){
  local i="$1" s
  s=$(cat "/sys/class/net/$i/speed" 2>/dev/null)
  [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -gt 0 ] && echo "$s" || echo ""
}

cmd_detect(){
  local iface rtt ram cores link virt kern cc_avail queues
  iface=$(detect_iface); [ -n "$iface" ] || die "找不到默认路由网卡"
  rtt=$(detect_rtt); ram=$(detect_ram_mb); cores=$(detect_cores)
  link=$(detect_link_mbps "$iface")
  # systemd-detect-virt 在裸机上输出 none 但退出码为 1, 不能用 || 兜底
  virt=$(systemd-detect-virt 2>/dev/null); [ -n "$virt" ] || virt=unknown
  kern=$(uname -r)
  cc_avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
  queues=$(ls -d /sys/class/net/"$iface"/queues/rx-* 2>/dev/null | wc -l)

  echo "── Machine profile ──"
  kv "Interface"   "$iface"
  kv "Driver"      "$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^driver/{print $2}')"
  kv "RX queues"   "$queues"
  kv "Link speed"  "${link:-n/a (virtual NIC)}"
  kv "Kernel"      "$kern"
  kv "Virt"        "$virt"
  kv "CPU cores"   "$cores"
  kv "Memory MB"   "$ram"
  kv "RTT to CN"   "${rtt:-probe failed}"
  kv "CC available" "$cc_avail"
  kv "BBR"         "$(echo "$cc_avail" | grep -qw bbr && echo 是 || (modprobe tcp_bbr 2>/dev/null && echo '是(需加载模块)' || echo 否))"

  mkdir -p "$STATE_DIR"
  cat > "$FACTS" <<EOF
IFACE=$iface
RTT_MS=${rtt:-0}
RAM_MB=$ram
CORES=$cores
LINK_MBPS=${link:-0}
KERNEL=$kern
VIRT=$virt
EOF
}

# ── 参数推导 ────────────────────────────────────────────────────────────────
# BDP(字节) = 带宽(Mbps) * 1e6 / 8 * RTT(s)
calc_bdp(){ awk -v b="$1" -v r="$2" 'BEGIN{printf "%d", b*1000000/8*(r/1000)}'; }

# tcp_mem(页). 内核在 pressure 阈值就开始缩窗, max 是硬顶.
# 小内存机器上把 max 设成内存的一半是 OOM 主因 —— 这里固定按 1/8 与 1/4 推导.
calc_tcp_mem(){
  local ram_mb="$1"
  awk -v m="$ram_mb" 'BEGIN{
    pg=m*1024/4;                      # 总内存页数
    low=int(pg/16); pres=int(pg/8); max=int(pg/4);
    if(low<4096) low=4096; if(pres<8192) pres=8192; if(max<16384) max=16384;
    printf "%d %d %d", low, pres, max
  }'
}

# 缓冲区上限 = 2 × BDP, 但要受全局 TCP 预算约束.
#
# 原先是死写的 [4MB, 64MB]. 64MB 这个数在两头都错：
#   高带宽机被无谓截断 —— 2G/149ms 的机器 2×BDP 是 71MB, 被砍成 64MB,
#   接收窗口只剩 32MB, 单流上限 1.93Gbps, 刚好够不到 2G（实测验证, 见 FINDINGS 14）.
#   小内存机又太松 —— 1GB 的机器也允许单个 socket 占 64MB, 几条大流就吃光 tcp_mem.
#
# 改成跟 tcp_mem 挂钩：单个 socket 最多占全局 TCP 预算的 1/8, 即至少要能容下
# 8 条大流同时跑满. tcp_mem 上限本身是内存的 1/4, 所以这个值 ≈ 内存的 1/32.
# 绝对上限 256MB —— 再大就是单条连接垄断全局预算了, 收益也早已递减.
#
# 注意 rmem_max/wmem_max 是「天花板」不是预分配：开着 tcp_moderate_rcvbuf,
# 连接从 default 值起步, 只有真跑得快才长上去. 而 tcp_mem 是内核硬性拦截的总量,
# 所以调大这里不会把机器 OOM 掉, 最坏是 TCP 进入内存压力后缓冲区被自动缩小.
calc_buf_max(){   # calc_buf_max <BDP字节> <内存MB>
  awk -v b="$1" -v m="$2" 'BEGIN{
    v   = b*2
    cap = m*32768              # tcp_mem上限(内存1/4)的 1/8 = 内存/32, 单位字节
    if(cap > 268435456) cap = 268435456      # 绝对上限 256MB
    if(v > cap) v = cap
    if(v < 4194304) v = 4194304              # 下限 4MB, 低于此连百兆都跑不满
    printf "%d", v
  }'
}

# buf_max 是被哪个条件定住的 —— 输出里说明白, 否则用户看到一个被截断的值
# 却以为是 2×BDP, 会去怀疑别的地方（我自己就在 9300 那台上绕过弯路）.
buf_max_reason(){   # buf_max_reason <BDP字节> <内存MB> <算出的buf_max>
  awk -v b="$1" -v m="$2" -v v="$3" 'BEGIN{
    cap = m*32768; if(cap > 268435456) cap = 268435456
    if(v <= 4194304 && b*2 < 4194304) { print "floor 4MB"; exit }
    if(v >= cap && b*2 > cap)         { printf "capped by tcp_mem budget"; exit }
    print "2 x BDP"
  }'
}

# 整形安全余量：按标称带宽分 5 档给固定值.
# 不用百分比是因为百分比在两端都别扭 —— 100M 机器 3% 才 3Mbit 太小,
# 2G 机器 3% 就是 60Mbit 太浪费. 分档更贴合实际.
# 余量的意义：sweep 是在某个时刻测的, 晚高峰线路会变差, 留一点缓冲避免那时暴丢包.
calc_margin(){
  local bw="$1"
  if   [ "$bw" -le 100 ]  2>/dev/null; then echo 5      # ≤100M   小水管, 5 就够
  elif [ "$bw" -le 300 ]  2>/dev/null; then echo 10     # 101-300M
  elif [ "$bw" -le 600 ]  2>/dev/null; then echo 15     # 301-600M  最常见档位
  elif [ "$bw" -le 1000 ] 2>/dev/null; then echo 25     # 601-1000M
  else                                        echo 40   # >1G      大带宽波动也大
  fi
}

# 预估整个调优流程会跑掉多少流量. sweep 是大头 ——
# 档数随带宽线性增长, 每档还要按该速率跑满 12 秒, 千兆机器能跑掉几十 GB.
# 有流量配额的用户必须提前知道.
# 粗扫步长随带宽放大. 固定 20 时 2Gbps 机器要扫 40 档、跑掉 137GB ——
# 精度靠后面的细扫补, 粗扫没必要那么密.
calc_step(){ awk -v b="$1" 'BEGIN{s=int(b/30/10+0.5)*10; if(s<20)s=20; printf "%d", s}'; }

estimate_traffic_gb(){
  local st; st=$(calc_step "$1")
  awk -v b="$1" -v st="$st" 'BEGIN{
    steps = int(b*0.4/st) + 1            # 粗扫档数 = (1.2b-0.8b)/步长
    mb  = b*10/8                         # probe   4 流 10 秒
    mb += b*0.4                          # 路径验证 40% 速率 8 秒
    mb += (steps+3) * b*12/8             # 粗扫 + 细扫 3 档, 每档 12 秒
    mb += b*10/8*2                       # verify 单流 + 4 流各 10 秒
    printf "%.1f", mb/1024
  }'
}

# 缓冲区默认值（起点）决定爬坡快慢, 但每 socket 都吃这么多额度.
#   proxy 角色并发上百条连接 → 保守, 1MB
#   bulk  角色只有少数大流   → 激进, 可到 BDP
calc_buf_default(){
  local role="$1" bdp="$2"
  case "$role" in
    proxy) echo 1048576 ;;
    bulk)  awk -v b="$bdp" 'BEGIN{v=b; if(v<1048576)v=1048576; if(v>8388608)v=8388608; printf "%d", v}' ;;
    *)     echo 2097152 ;;
  esac
}

# ── 快照与回滚 ──────────────────────────────────────────────────────────────
take_snapshot(){
  mkdir -p "$STATE_DIR"
  [ -f "$SNAPSHOT" ] && { info "Snapshot already exists, keeping the earliest one"; return; }
  # 机器已经被调过（手工或旧版本）却没有快照时, 当前状态不能当基线 ——
  # 那样 rollback 只会回到"调优后", 永远回不到出厂. 必须让用户先明确基线.
  if [ -f "$SYSCTL_FILE" ] || [ -f "$QDISC_SCRIPT" ]; then
    warn "检测到本机已有调优配置, 但没有出厂快照."
    warn "现在存快照会把「已调优状态」误记成基线, 导致 rollback 失效."
    warn "请先二选一："
    warn "  a) 手工写好出厂值到 $SNAPSHOT（格式见 docs）"
    warn "  b) 先 $(disp) rollback 回到出厂, 再重新 tune"
    warn "  c) 确认无需回滚能力, 则: touch $SNAPSHOT"
    die "已中止, 未做任何改动" 1
  fi
  local iface; iface=$(detect_iface)
  {
    echo "# tcpfit pre-tune snapshot  $(date -u +%FT%TZ)"
    echo "KERNEL=$(uname -r)"
    for k in net.ipv4.tcp_congestion_control net.core.default_qdisc \
             net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_mem \
             net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default \
             net.core.netdev_max_backlog net.core.somaxconn net.ipv4.tcp_adv_win_scale \
             net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_mtu_probing; do
      printf '%s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null)"
    done
    echo "# route: $(ip route show default)"
    echo "# qdisc: $(tc qdisc show dev "$iface" 2>/dev/null | head -1)"
  } > "$SNAPSHOT"
  ok "Snapshot saved: $SNAPSHOT"
}

cmd_rollback(){
  need_root
  migrate_legacy
  info "回滚中…"
  rm -f "$SYSCTL_FILE" "$ROUTE_HOOK"
  systemctl disable --now tcpfit-qdisc.service >/dev/null 2>&1
  rm -f "$QDISC_UNIT" "$QDISC_SCRIPT"
  systemctl daemon-reload >/dev/null 2>&1
  local iface; iface=$(detect_iface)
  tc qdisc del dev "$iface" root 2>/dev/null
  local gw; gw=$(detect_gw)
  [ -n "$gw" ] && ip route replace default via "$gw" dev "$iface" 2>/dev/null
  # 逐项写回快照值
  if [ -f "$SNAPSHOT" ]; then
    grep -E '^net\.' "$SNAPSHOT" | while IFS='=' read -r k v; do
      k=$(echo "$k" | xargs); v=$(echo "$v" | xargs)
      [ -n "$k" ] && [ -n "$v" ] && sysctl -qw "$k=$v" 2>/dev/null
    done
    ok "已按快照还原 sysctl"
  else
    warn "找不到快照, 仅移除了调优文件；重启后内核默认值生效"
  fi
  ok "回滚完成"
}

# ── 基础调优 ────────────────────────────────────────────────────────────────
cmd_tune(){
  need_root
  migrate_legacy
  self_install
  local role=mixed bw="" rtt="" no_initcwnd=0 peer=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --role) role="$2"; shift 2 ;;
      --bw)   bw="$2";   shift 2 ;;
      --rtt)  rtt="$2";  shift 2 ;;
      --peer) peer="$2"; shift 2 ;;
      --no-initcwnd) no_initcwnd=1; shift ;;
      *) die "未知参数: $1" ;;
    esac
  done
  case "$role" in proxy|bulk|mixed) ;; *) die "role 只能是 proxy / bulk / mixed" ;; esac

  local iface ram; iface=$(detect_iface); ram=$(detect_ram_mb)
  [ -n "$iface" ] || die "找不到默认路由网卡"
  [ -n "$rtt" ] || rtt=$(detect_rtt)
  [ -n "$rtt" ] && [ "$rtt" -gt 0 ] 2>/dev/null || die "无法确定 RTT, 请用 --rtt 指定"
  # --bw auto: 现场探测. 虚拟网卡读不到标称速率, 这是最常见的情况.
  if [ "$bw" = auto ]; then
    [ -n "$peer" ] || die "--bw auto 需要同时给 --peer <近处的iperf3服务器>"
    command -v iperf3 >/dev/null || die "--bw auto 需要 iperf3"
    info "Probing available bandwidth..."
    bw=$(probe_bandwidth "$peer" "$iface") || bw=""
    [ -n "$bw" ] && ok "Measured ~${bw} Mbps" || die "bandwidth probe failed" 2
  fi
  [ -n "$bw" ] || bw=$(detect_link_mbps "$iface")
  if ! { [ -n "$bw" ] && [ "$bw" -gt 0 ] 2>/dev/null; }; then
    warn "本机是虚拟网卡, 读不到标称速率. 三选一："
    warn "  a) 知道套餐带宽:  $(disp) tune --role $role --bw <Mbps>"
    warn "  b) 现场探测:      $(disp) tune --role $role --bw auto --peer <近处iperf3服务器>"
    warn "  c) 先单独探测:    $(disp) probe --peer <近处iperf3服务器>"
    die "无法确定带宽, 已中止" 1
  fi

  take_snapshot

  local bdp buf_max buf_def tcp_mem
  bdp=$(calc_bdp "$bw" "$rtt")
  buf_max=$(calc_buf_max "$bdp" "$ram")
  buf_def=$(calc_buf_default "$role" "$bdp")
  tcp_mem=$(calc_tcp_mem "$ram")

  info "Derived from: ${bw} Mbps / RTT ${rtt} ms / ${ram} MB RAM / role $role"
  kv "  BDP"            "$(awk -v v="$bdp" 'BEGIN{printf "%.1f MB", v/1048576}')"
  kv "  Buffer max"     "$(awk -v v="$buf_max" 'BEGIN{printf "%.0f MB", v/1048576}')  ($(buf_max_reason "$bdp" "$ram" "$buf_max"))"
  kv "  Buffer default" "$(awk -v v="$buf_def" 'BEGIN{printf "%.0f MB", v/1048576}')  (role $role)"
  kv "  tcp_mem"        "$(echo "$tcp_mem" | awk '{printf "%.0fM / %.0fM / %.0fM", $1*4/1024, $2*4/1024, $3*4/1024}')  (RAM 1/16, 1/8, 1/4)"

  modprobe tcp_bbr 2>/dev/null
  echo tcp_bbr > /etc/modules-load.d/tcpfit-bbr.conf
  local cc=bbr
  sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr || {
    warn "kernel has no BBR, falling back to cubic (much smaller gain)"; cc=cubic; }

  cat > "$SYSCTL_FILE" <<EOF
# 由 tcpfit v$VERSION 生成  $(date -u +%FT%TZ)
# 带宽=${bw}Mbps  RTT=${rtt}ms  内存=${ram}MB  角色=${role}
# 每个值的依据见 docs/FINDINGS.md, 勿手改；改用 tcpfit tune 重新生成

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $cc

# 缓冲区：上限=2×BDP, 默认值按角色（默认值决定爬坡快慢, 也决定每连接内存占用）
net.core.rmem_max = $buf_max
net.core.wmem_max = $buf_max
net.core.rmem_default = $buf_def
net.core.wmem_default = $buf_def
net.ipv4.tcp_rmem = 4096 $buf_def $buf_max
net.ipv4.tcp_wmem = 4096 $buf_def $buf_max
# 全局 TCP 内存上限, 按物理内存推导. 设太高是小内存机 OOM 的主因.
net.ipv4.tcp_mem = $tcp_mem

net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = 1

net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 4000
net.core.optmem_max = 65536
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fastopen = 3

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.ip_local_port_range = 1024 65535

vm.min_free_kbytes = 32768
fs.file-max = 1000000

# 刻意不设的项（见 FINDINGS.md）:
#   tcp_notsent_lowat  —— 低核数机器上压吞吐
#   tcp_reordering=300 —— 现代内核走 RACK, 调高只推迟快速重传
EOF

  sysctl -qp "$SYSCTL_FILE" 2>/dev/null
  ok "sysctl applied: $SYSCTL_FILE"

  if [ "$no_initcwnd" = 0 ]; then
    local gw; gw=$(detect_gw)
    if [ -n "$gw" ]; then
      ip route replace default via "$gw" dev "$iface" initcwnd 32 initrwnd 32 2>/dev/null \
        && ok "initcwnd/initrwnd = 32" || warn "initcwnd not applied (unsupported on some hypervisors)"
      if [ -d /etc/networkd-dispatcher/routable.d ]; then
        cat > "$ROUTE_HOOK" <<'H'
#!/bin/bash
GW=$(ip route show default | awk '{print $3; exit}')
IF=$(ip route show default | awk '{print $5; exit}')
[ -n "$GW" ] && [ -n "$IF" ] && ip route replace default via "$GW" dev "$IF" initcwnd 32 initrwnd 32
exit 0
H
        chmod +x "$ROUTE_HOOK"
      fi
    fi
  fi

  # 一键流程里这些收尾由 wizard 统一打印, 避免中英文交错
  [ "$WIZARD" = 1 ] && return 0

  info "基础调优完成. 下一步跑 sweep 找限速器拐点 —— 那才是大头."
  echo "  $(disp) sweep --peer <近处的iperf3服务器> --nominal $bw"

  # 小内存机不加 swap 就是定时炸弹：实测过 tcp_mem 撑爆内存把代理进程连杀 7 次
  if [ "$ram" -le 1024 ] && ! swapon --show 2>/dev/null | grep -q .; then
    echo
    warn "本机内存 ${ram}MB 且无 swap, 跑代理建议加一个：$(disp) harden --swap 2G"
  fi
}

# ── 系统加固 ────────────────────────────────────────────────────────────────
# 与网络参数无关, 但小内存机不加 swap 就没有任何缓冲余地：TCP 缓冲区一涨,
# 内核直接杀进程. 表现是"测速跑一半掉速", 要翻 journalctl 才看得出来.
cmd_harden(){
  need_root
  local swap_size=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --swap) swap_size="$2"; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [ -n "$swap_size" ] || die "需要 --swap <大小>, 例如 --swap 2G 或 --swap 2"

  # 允许只写数字, 按 GB 算 —— 菜单里让用户输 1-20 的数字
  case "$swap_size" in *[!0-9]*) ;; *) swap_size="${swap_size}G" ;; esac
  local gb="${swap_size%[GgMm]}"
  [ "$gb" -ge 1 ] 2>/dev/null && [ "$gb" -le 20 ] 2>/dev/null || die "swap 大小请填 1-20 之间的数字（GB）"

  if swapon --show 2>/dev/null | grep -q .; then
    info "已有 swap, 跳过: $(free -h | awk '/Swap/{print $2}')"
    return 0
  fi
  info "创建 ${swap_size} swap…"
  fallocate -l "$swap_size" /swapfile 2>/dev/null \
    || dd if=/dev/zero of=/swapfile bs=1M count=$(( gb * 1024 )) status=none
  chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile \
    || die "swap 创建失败"
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "swap 已启用: $(free -h | awk '/Swap/{print $2}')"
  # 只在内存真的紧张时才用 swap, 避免平时把热数据换出去拖慢代理
  sysctl -qw vm.swappiness=10
  grep -q '^vm.swappiness' "$SYSCTL_FILE" 2>/dev/null || echo "vm.swappiness = 10" >> "$SYSCTL_FILE"
  ok "vm.swappiness = 10"
}

# ── 出向整形 ────────────────────────────────────────────────────────────────
# HTB 做全局上限（多流场景必需）, fq 叶子做 hrtimer 逐包 pacing.
# burst 压到 32k：HTB 默认 burst 按 rate/HZ 算, 会放行微突发打穿限速器.
write_qdisc(){
  local rate="$1" iface="$2"
  cat > "$QDISC_SCRIPT" <<EOF
#!/bin/bash
IF=${iface}
RATE=\${1:-${rate}}
tc qdisc del dev \$IF root 2>/dev/null
tc qdisc add dev \$IF root handle 1: htb default 10
tc class add dev \$IF parent 1: classid 1:10 htb rate \${RATE}mbit ceil \${RATE}mbit burst 32k cburst 32k quantum 1514
tc qdisc add dev \$IF parent 1:10 handle 10: fq limit 40960 flow_limit 8192 maxrate \${RATE}mbit
EOF
  chmod +x "$QDISC_SCRIPT"
  cat > "$QDISC_UNIT" <<EOF
[Unit]
Description=tcpfit egress shaper
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$QDISC_SCRIPT $rate
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1
  # 用 --now 而不是只 enable：否则 tc 规则虽已生效, systemctl is-active 却显示
  # inactive, status 里看着像坏了. 让 unit 状态和实际状态一致.
  systemctl enable --now tcpfit-qdisc.service >/dev/null 2>&1
}

cmd_shape(){
  need_root
  local rate="" off=0 iface
  while [ $# -gt 0 ]; do
    case "$1" in
      --rate) rate="$2"; shift 2 ;;
      --off)  off=1; shift ;;
      *) die "未知参数: $1" ;;
    esac
  done
  iface=$(detect_iface)

  # 没有限速器可躲的机器（sweep 全程干净）, HTB 的硬上限只会限制自己 ——
  # 而且 HTB 实际投递只有标称的 93-96%, 设 2Gbit 就永远摸不到 2Gbit.
  # 移除后根 qdisc 退回纯 fq：BBR 的逐 socket pacing 仍然生效, 只是没有聚合上限.
  # 注意不动 sysctl, 基础调优完整保留 —— 这是它和 rollback 的区别.
  if [ "$off" = 1 ]; then
    systemctl disable --now tcpfit-qdisc.service >/dev/null 2>&1
    rm -f "$QDISC_UNIT" "$QDISC_SCRIPT"
    systemctl daemon-reload >/dev/null 2>&1
    tc qdisc del dev "$iface" root 2>/dev/null
    tc qdisc add dev "$iface" root fq 2>/dev/null
    ok "整形已移除, qdisc 恢复为纯 fq"
    info "BBR 的逐 socket pacing 仍然生效, 只是没有了聚合速率上限."
    info "基础调优（拥塞控制 / 缓冲区）未受影响."
    [ "$WIZARD" = 1 ] || tc qdisc show dev "$iface" | head -1
    return 0
  fi

  [ -n "$rate" ] || die "需要 --rate <Mbit>, 或用 --off 移除整形"
  take_snapshot
  write_qdisc "$rate" "$iface"
  systemctl restart tcpfit-qdisc.service 2>/dev/null || "$QDISC_SCRIPT" "$rate"
  ok "HTB ${rate} Mbit + fq leaf pacing on ${iface}"
  ok "tcpfit-qdisc.service enabled (survives reboot)"
  [ "$WIZARD" = 1 ] || tc class show dev "$iface"
}

# ── 带宽探测 ────────────────────────────────────────────────────────────────
# 虚拟网卡读不到标称速率(/sys/class/net/*/speed 为 -1), 而用户未必记得买的是多少兆.
# 这里用带 pacing 的多流测试估一个可用带宽, 供 tune 推导 BDP.
# 注意：这只是"够用的估计", 真正的限速器拐点仍要靠 sweep 实测.
probe_bandwidth(){
  local peer="$1" iface="$2" dur="${3:-10}"
  local saved_shaper=0
  [ -x "$QDISC_SCRIPT" ] && saved_shaper=1
  _probe_restore(){
    tc qdisc del dev "$iface" root 2>/dev/null
    [ "$saved_shaper" = 1 ] && "$QDISC_SCRIPT" >/dev/null 2>&1 || tc qdisc add dev "$iface" root fq 2>/dev/null
  }
  trap '_probe_restore; exit 130' INT TERM
  # 用 fq 做 pacing 但不设上限：既避免突发打穿限速器, 又能探到真实上限
  tc qdisc del dev "$iface" root 2>/dev/null
  tc qdisc add dev "$iface" root fq 2>/dev/null
  local res gp
  for a in 1 2 3; do res=$(run_iperf "$peer" "$dur" 4); [ -n "$res" ] && break; sleep 8; done
  trap - INT TERM
  _probe_restore
  [ -n "$res" ] || { echo ""; return 1; }
  gp=$(echo "$res" | awk '{print $1}')
  # 取最近的 50Mbps 档. 早期版本无脑向上取整, 实测把 305Mbps 估成 350,
  # 导致 sweep 的扫描区间整体偏高.
  awk -v g="$gp" 'BEGIN{printf "%d", int(g/50+0.5)*50}'
}

cmd_probe(){
  need_root
  command -v iperf3 >/dev/null || die "需要 iperf3"
  local peer=""
  while [ $# -gt 0 ]; do
    case "$1" in --peer) peer="$2"; shift 2 ;; *) die "未知参数: $1" ;; esac
  done
  [ -n "$peer" ] || die "需要 --peer <近处的iperf3服务器>"
  local iface; iface=$(detect_iface)
  info "探测可用带宽（4 并发 + pacing, 约 15 秒）…"
  local bw; bw=$(probe_bandwidth "$peer" "$iface")
  [ -n "$bw" ] || die "探测失败, 检查对端 $peer 是否可达/空闲" 2
  mkdir -p "$STATE_DIR"; echo "BW_MBPS=$bw" > "$STATE_DIR/probe.result"
  ok "估计可用带宽 ≈ ${bw} Mbps"
  echo
  echo "  这只是给 tune 算 BDP 用的估计值, 真正的限速器拐点靠 sweep 实测."
  echo "  下一步: $0 tune --role <proxy|bulk|mixed> --bw $bw"
}

# ── 限速器拐点扫描 ──────────────────────────────────────────────────────────
# 原理: 端口上的限速器(policer)看的是瞬时速率. 不加 pacing 的 TCP 发送是突发的,
# 平均速率没超也会被打穿. 加 fq pacing 后可以贴着真实上限跑而几乎不丢包.
# 拐点 = 重传开始跳变的那一档；取前一档再退安全余量.
# NETTUNE_VERBOSE=1 时把 iperf3 原始输出打到 stderr, 让用户看到测速在跑
# $1=peer $2=dur $3=parallel [$4=port]  -> "goodput retrans"
# 公共节点开 5201-5210 十个实例, 指定端口忙时自动换 —— 否则单端口一忙就整个失败.
run_iperf(){
  local out raw tmp port ports first="${4:-${PEER_PORT:-5201}}"
  ports="$first"
  for p in 5201 5202 5203 5204 5205 5206 5207 5208 5209 5210; do
    [ "$p" = "$first" ] || ports="$ports $p"
  done
  tmp=$(mktemp)
  for port in $ports; do
    : > "$tmp"
    timeout $(( $2 + 25 )) iperf3 -c "$1" -p "$port" -t "$2" -P "$3" -f m >"$tmp" 2>&1 &
    spin_wait $! "测速中… ${2}s × ${3} 流  →  $1:$port"
    grep -q "busy running a test\|control socket has closed\|Connection refused" "$tmp" 2>/dev/null || break
  done
  raw=$(cat "$tmp"); rm -f "$tmp"
  [ "${NETTUNE_VERBOSE:-0}" = 1 ] && echo "$raw" | sed 's/^/      | /' >&2
  out=$(echo "$raw" | grep -E "$( [ "$3" -gt 1 ] && echo 'SUM.*sender' || echo 'sender' )" | tail -1)
  [ -z "$out" ] && { echo ""; return; }
  echo "$out" | awk '{print $(NF-3), $(NF-1)}'
}

# 丢包率(%) = 重传数 / 发出的包数. 包数按 1448 字节 MSS 估算.
#
# 为什么不能用绝对次数：阈值 100 在 300M 机上相当于 0.032% 丢包,
# 在 7.4G 机上只有 0.0014% —— 严了 25 倍. 实测踩过：一台 10G 口的机器
# 第一档 7440Mbit 实测 7001Mbps、重传 101（丢包率 0.0014%, 链路干净得离谱）,
# 却被判成撞了限速器, LAST_OK 为空直接报 "no usable rate measured" 退出,
# 整个扫描一档都没跑成.
#
# 七组真实数据回归：干净侧最高 0.0017%, 撞限速器最低 1.3541%.
# 阈值取 0.1%, 距两侧分别有 59 倍和 13.5 倍余量, 且自动适配任何带宽.
loss_pct(){   # loss_pct <重传数> <吞吐Mbps> <秒数>
  awk -v rt="$1" -v gp="$2" -v d="$3" 'BEGIN{
    pk = gp*1000000*d/8/1448          # 发出的包数
    if(pk < 1) pk = 1
    printf "%.4f", rt*100/pk
  }'
}

cmd_sweep(){
  need_root
  command -v iperf3 >/dev/null || die "需要 iperf3: apt install -y iperf3 / yum install -y iperf3"
  # GAP: 档与档之间的静置时间, 让上一条流的状态排空, 避免相邻两档互相干扰
  local peer="" nominal="" lo="" hi="" step="" dur=12 par=1 margin="" thresh=0.1 refine=1 GAP=3
  while [ $# -gt 0 ]; do
    case "$1" in
      --peer) peer="$2"; shift 2 ;;
      --port) PEER_PORT="$2"; shift 2 ;;
      --nominal) nominal="$2"; shift 2 ;;
      --from) lo="$2"; shift 2 ;;
      --to) hi="$2"; shift 2 ;;
      --step) step="$2"; shift 2 ;;
      --dur) dur="$2"; shift 2 ;;
      --parallel) par="$2"; shift 2 ;;
      --margin) margin="$2"; shift 2 ;;
      --gap) GAP="$2"; shift 2 ;;
      --no-refine) refine=0; shift ;;
      --loss-threshold|--retrans-threshold) thresh="$2"; shift 2 ;;   # 单位是百分比
      *) die "未知参数: $1" ;;
    esac
  done
  [ -n "$peer" ] || die "需要 --peer <iperf3服务器>, 选延迟低的, 测的是本机端口上限而非跨国链路"
  local iface; iface=$(detect_iface)
  [ -n "$nominal" ] || nominal=$(detect_link_mbps "$iface")
  [ -n "$nominal" ] || die "需要 --nominal <标称带宽Mbps>"
  [ -n "$step" ] || step=$(calc_step "$nominal")
  [ -n "$lo" ] || lo=$(( nominal * 80 / 100 ))
  [ -n "$hi" ] || hi=$(( nominal * 120 / 100 ))

  [ "$WIZARD" = 1 ] || traffic_mark
  info "Scanning ${lo} -> ${hi} Mbit, step ${step}, ${dur}s each, threshold loss > ${thresh}%"
  info "Peer ${peer}:${PEER_PORT}"
  echo
  # 表头一律 ASCII：printf 的 %-Ns 按字节补齐, 中文列宽必错位
  printf '  %-10s %12s %9s %8s  %s\n' "Rate/Mbit" "Goodput/Mbps" "Retrans" "Loss%" "Verdict"

  # 扫描会反复替换 qdisc；无论正常结束、拐点 break 还是被 Ctrl-C,
  # 都必须把机器恢复原状 —— 否则会被留在那个暴丢包的档位上.
  local had_shaper=0
  [ -x "$QDISC_SCRIPT" ] && had_shaper=1
  restore_qdisc(){
    tc qdisc del dev "$iface" root 2>/dev/null
    if [ "$had_shaper" = 1 ]; then
      "$QDISC_SCRIPT" >/dev/null 2>&1 && info "Pre-sweep qdisc restored"
    else
      tc qdisc add dev "$iface" root fq 2>/dev/null
      info "Test qdisc cleared, back to plain fq"
    fi
  }
  trap 'echo; warn "interrupted, restoring qdisc..."; restore_qdisc; exit 130' INT TERM

  # 扫一段区间. 结果放进全局 LAST_OK(最后一个干净档) 与 BROKE_AT(重传跳变的那档)
  LAST_OK=""; BROKE_AT=""; SLOW_HITS=0; PEER_TOO_SLOW=0
  scan_range(){
    local a b st r res gp rt lp prev_gp=0 verdict
    a=$1; b=$2; st=$3
    for (( r=a; r<=b; r+=st )); do
      tc qdisc del dev "$iface" root 2>/dev/null
      tc qdisc add dev "$iface" root fq maxrate "${r}mbit" limit 40960 flow_limit 8192
      res=""
      # 进度提示交给 run_iperf 里的转圈, 这里不要再打占位符（会和转圈重叠）
      for _ in 1 2 3; do res=$(run_iperf "$peer" "$dur" "$par"); [ -n "$res" ] && break; sleep 8; done
      if [ -z "$res" ]; then printf '  %-10s %12s %9s %8s  %s\n' "$r" "-" "-" "-" "peer busy, skipped"; continue; fi
      gp=$(echo "$res" | awk '{print $1}'); rt=$(echo "$res" | awk '{print $2}')
      lp=$(loss_pct "$rt" "$gp" "$dur")
      verdict="ok"
      # 判定用丢包率而非绝对重传数 —— 见 loss_pct 上方注释
      if awk -v l="$lp" -v t="$thresh" 'BEGIN{exit !(l > t)}' 2>/dev/null; then
        printf '  %-10s %12s %9s %8s  %s\n' "$r" "$gp" "$rt" "$lp" "$(_c '0;31' 'loss spike')"
        BROKE_AT=$r; return 0
      fi
      # 吞吐远低于限速值、重传却很低 = 整形器压根没被触发, 瓶颈在对端.
      # 「重传低」这个条件必不可少：吞吐低但重传高是真撞限速器, 那是有效数据.
      if awk -v g="$gp" -v r="$r" 'BEGIN{exit !(g < r*0.7)}' 2>/dev/null; then
        SLOW_HITS=$(( SLOW_HITS + 1 ))
        printf '  %-10s %12s %9s %8s  %s\n' "$r" "$gp" "$rt" \
          "$(_c '0;33' "only $(awk -v g="$gp" -v r="$r" 'BEGIN{printf "%d", g*100/r}')% of target")"
        [ "$SLOW_HITS" -ge 3 ] && { PEER_TOO_SLOW=1; return 0; }
        LAST_OK=$r; prev_gp=$gp; sleep "$GAP"; continue
      fi
      SLOW_HITS=0
      # 吞吐不再增长也说明到顶了
      if awk -v x="$gp" -v y="$prev_gp" 'BEGIN{exit !(y>0 && x < y*1.01)}'; then verdict="no further gain"; fi
      printf '  %-10s %12s %9s %8s  %s\n' "$r" "$gp" "$rt" "$lp" "$verdict"
      LAST_OK=$r; prev_gp=$gp
      sleep "$GAP"
    done
  }

  scan_range "$lo" "$hi" "$step"

  if [ "$PEER_TOO_SLOW" = 1 ]; then
    echo
    trap - INT TERM
    restore_qdisc
    [ "$WIZARD" = 1 ] && printf '\n  %s════ 结果 ══════════════════════════════════════════════%s\n' "$bold" "$plain"
    echo
    warn "对端速率不够, 无法测出本机限速器 —— 已暂停调优."
    echo
    echo "  怎么办："
    echo "    1) 换一个更快的对端. 对端带宽必须明显高于本机（${nominal}Mbps）"
    echo "    2) 直接用公共节点（选对端时回车）, Leaseweb 机房带宽足够"
    echo "    3) 如果确定本机带宽没那么高, 重跑时把带宽填成实际值"
    echo
    info "基础调优（拥塞控制 / 缓冲区）已生效."
    traffic_report
    exit 2
  fi

  # 粗扫只能定位到「拐点在 LAST_OK 与 BROKE_AT 之间」, 区间宽度就是步长.
  # 在这个区间用 1/4 步长再扫一遍, 把真实上限找准 —— 步长 20 时能多挖回十几 Mbps.
  if [ "$refine" = 1 ] && [ -n "$LAST_OK" ] && [ -n "$BROKE_AT" ] && [ $(( BROKE_AT - LAST_OK )) -gt 5 ]; then
    local fine coarse_broke
    coarse_broke=$BROKE_AT                       # 先存下粗扫的上界, 下面会被 scan_range 重置
    fine=$(( step / 4 )); [ "$fine" -lt 5 ] && fine=5
    echo
    info "Knee between ${LAST_OK} and ${coarse_broke}, refining with step ${fine}"
    printf '  %-10s %12s %9s %8s  %s\n' "Rate/Mbit" "Goodput/Mbps" "Retrans" "Loss%" "Verdict"
    BROKE_AT=""
    scan_range $(( LAST_OK + fine )) $(( coarse_broke - fine )) "$fine"
  fi

  echo
  trap - INT TERM
  restore_qdisc
  echo
  local knee="$LAST_OK"
  [ -n "$knee" ] || { warn "no usable rate measured, check that the peer is reachable"; exit 2; }
  # 安全余量按标称带宽分档. 早期用固定 20Mbit, 在 300M 机器上白丢 19Mbps
  # （实测 300 档重传比 280 档还少）, 说明一个数字套所有带宽不合理.
  [ -n "$margin" ] || margin=$(calc_margin "$nominal")
  local final=$(( knee - margin )); [ "$final" -lt 1 ] && final=$knee
  mkdir -p "$STATE_DIR"; echo "KNEE=$knee"$'\n'"RECOMMEND=$final" > "$STATE_DIR/sweep.result"
  # 一键流程里这些数字由 wizard 在「结果」里统一呈现, 这里只出执行日志
  if [ "$WIZARD" = 1 ]; then
    ok "Knee ${knee} Mbit, margin ${margin} Mbit -> shape at ${final} Mbit"
    return 0
  fi
  ok "实测上限 ${knee} Mbit, 按 ${nominal}M 档位退 ${margin} 余量 → 建议整形值 ${final} Mbit"
  echo
  echo "  应用: $(disp) shape --rate $final"
  echo "  (扫描本身不会改变整形配置, 上面这条才会)"
  traffic_report
}

# ── 验证与状态 ──────────────────────────────────────────────────────────────
cmd_status(){
  local iface; iface=$(detect_iface)
  echo "── Current configuration ──"
  kv "Kernel"      "$(uname -r)"
  kv "Congestion"  "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  kv "Default qdisc" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  kv "Active qdisc" "$(tc qdisc show dev "$iface" 2>/dev/null | head -1 | awk '{print $2}')"
  kv "Egress shaper" "$(tc class show dev "$iface" 2>/dev/null | grep -oE 'rate [0-9]+[MKG]bit' | head -1 || echo 'none')"
  kv "tcp_rmem"    "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | tr '\t' ' ')"
  kv "tcp_wmem"    "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | tr '\t' ' ')"
  kv "tcp_mem"     "$(sysctl -n net.ipv4.tcp_mem 2>/dev/null | awk '{printf "%.0fM/%.0fM/%.0fM", $1*4/1024,$2*4/1024,$3*4/1024}')"
  kv "Backlog"     "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)"
  kv "initcwnd"    "$(ip route show default | grep -oE 'initcwnd [0-9]+' || echo '默认(10)')"
  kv "tcpfit conf" "$([ -f "$SYSCTL_FILE" ] && echo applied || echo absent)"
  kv "Shaper svc"  "$(systemctl is-enabled tcpfit-qdisc.service 2>/dev/null || echo 未安装)"
  kv "Snapshot"    "$([ -f "$SNAPSHOT" ] && echo "$SNAPSHOT" || echo 无)"
  echo
  echo "── Health ──"
  local out rt
  out=$(awk '/^Tcp: [0-9]/{print $12, $13}' /proc/net/snmp)
  rt=$(echo "$out" | awk '{if($1>0) printf "%.3f%%", $2*100/$1; else print "n/a"}')
  kv "Retrans (boot)" "$rt  (cumulative since boot; use Verify for current)"
  kv "qdisc drops" "$(tc -s class show dev "$iface" 2>/dev/null | grep -oP 'dropped \K[0-9]+' | head -1 || echo n/a)"
  kv "Memory"      "$(free -m | awk '/Mem:/{print "已用 "$3"MB / 可用 "$7"MB / 共 "$2"MB"}')"
  kv "Swap"        "$(free -m | awk '/Swap:/{if($2==0) print "none (recommended on low-memory hosts)"; else print $3"/"$2" MB"}')"
  # grep -c 无匹配时输出 0 但退出码 1, 不能用 || 兜底, 否则会打印两个 0
  kv "OOM (1h)"    "$(journalctl --since '-1 hour' 2>/dev/null | grep -c 'oom-kill') in last hour"
}

# 验证「本机端口能力」. 刻意用近端对端 —— 测的是服务器出口能发多快、
# 整形有没有生效, 不是到国内的速度（那取决于线路质量, 见 cmd_cntest）.
# 实测 + 判定拆开：一键流程要把执行日志（英文）和结论（中文）分在两段里打印.
VS1=""; VR1=""; VS4=""; VR4=""
verify_measure(){
  local peer="$1" res
  VS1=""; VR1=""; VS4=""; VR4=""
  res=$(run_iperf "$peer" 10 1); [ -n "$res" ] && { VS1=$(echo "$res"|awk '{print $1}'); VR1=$(echo "$res"|awk '{print $2}'); }
  sleep 3
  res=$(run_iperf "$peer" 10 4); [ -n "$res" ] && { VS4=$(echo "$res"|awk '{print $1}'); VR4=$(echo "$res"|awk '{print $2}'); }
}

# 打印验证结果表 + 结论. $1 = 当前整形值(Mbit, 可空)
verify_verdict(){
  local target="${1:-}"
  echo "  验证"
  printf '      %s %s %s\n' "$(_pad "" 14)" "$(_rpad "吞吐 Mbps" 12)" "$(_rpad "重传" 11)"
  printf '      %s %s %s\n' "$(_pad "单流" 14)"     "$(_rpad "${VS1:-测试失败}" 12)" "$(_rpad "${VR1:--}" 11)"
  printf '      %s %s %s\n' "$(_pad "4 流并发" 14)" "$(_rpad "${VS4:-测试失败}" 12)" "$(_rpad "${VR4:--}" 11)"
  echo
  # 拿实测和整形值比, 给出结论而不是丢一堆数字
  if [ -n "$VS4" ] && [ -n "$target" ] && [ "$target" -gt 0 ] 2>/dev/null; then
    local pct; pct=$(awk -v a="$VS4" -v b="$target" 'BEGIN{printf "%.0f", a*100/b}')
    if   [ "$pct" -ge 90 ] 2>/dev/null; then ok "达到整形值的 ${pct}%, 端口能力正常"
    elif [ "$pct" -ge 75 ] 2>/dev/null; then info "达到整形值的 ${pct}%, 偏低但可接受（对端可能被其他人占用）"
    else warn "只达到整形值的 ${pct}%, 建议换个对端重测"; fi
  fi
  if [ -n "$VR4" ]; then
    if   [ "${VR4%.*}" -le 50 ]  2>/dev/null; then ok "重传 ${VR4}, 整形工作正常"
    elif [ "${VR4%.*}" -le 500 ] 2>/dev/null; then info "重传 ${VR4}, 略高但不影响"
    else warn "重传 ${VR4} 偏高 —— 整形值可能设高了, 建议重跑菜单 3 重新找拐点"; fi
  fi
}

cmd_verify(){
  local peer="" peer_name="" peer_rtt=""
  while [ $# -gt 0 ]; do
    case "$1" in --peer) peer="$2"; shift 2 ;; --name) peer_name="$2"; shift 2 ;; *) shift ;; esac
  done
  local iface shaper; iface=$(detect_iface)
  shaper=$(tc class show dev "$iface" 2>/dev/null | grep -oE 'rate [0-9]+[MKG]bit' | head -1 | awk '{print $2}')

  echo
  printf '  %s本机端口能力验证%s\n' "$bold" "$plain"
  rule
  echo "  测的是：服务器出口能发多快、整形有没有生效"
  echo "  不测：到国内的速度（那取决于线路质量, 跟服务器配置无关）"
  echo

  if [ -z "$peer" ]; then
    warn "没有可用对端, 只显示配置"
    cmd_status; return 0
  fi
  peer_rtt=$(ping -c 2 -q -W 2 "$peer" 2>/dev/null | awk -F'/' '/rtt|round-trip/{printf "%.0f", $5}')
  printf "  对端    %s   RTT %sms   端口 %s\n" "$peer" "${peer_rtt:-?}" "$PEER_PORT"
  printf "  整形    %s\n" "${shaper:-未设置}"
  echo
  command -v iperf3 >/dev/null || { warn "无 iperf3, 跳过实测"; return 0; }

  verify_measure "$peer"
  verify_verdict "${shaper%Mbit}"
  rule
}

# ── 交互式菜单 ──────────────────────────────────────────────────────────────
#
# 设计原则：用户只需要回答"这机器干什么用的", 其余全部自动.
# 尤其是 iperf3 对端 —— 让用户自己挑服务器是最大的使用门槛, 这里自动 ping 一圈选最近的.

# 公共 iperf3 服务器池. 挑选标准：长期在线、允许匿名测试、地理分布覆盖主要机房区域.
# 公共 iperf3 测速节点池. 格式: 主机|地区|提供商
#
# 这些是第三方免费提供的公共测试服务器, sweep 会向它们发送测试流量.
# 节点来源与实测稳定性（2026-08 在欧洲机器上各测 3 次握手）：
#   Leaseweb   全球机房, 18 节点中 15 个 3/3 —— 最稳, 优先用
#   Clouvider  5 节点中仅 2 个 3/3 —— 时好时坏, 作备选
#   OVH        新加坡节点 3/3
# 注: 早期用 timeout 15 测稳定性, 对 280ms+ 的远节点连握手都不够, 误判成不可用.
# 判定节点好坏不能用固定超时 —— 和 RTT 一刀切是同一类错误.
# 完整公共列表见 https://iperf3serverlist.net
PEER_POOL="
speedtest.hkg12.hk.leaseweb.net|香港|Leaseweb
speedtest.sin1.sg.leaseweb.net|新加坡|Leaseweb
sgp.proof.ovh.net|新加坡|OVH
speedtest.syd12.au.leaseweb.net|悉尼|Leaseweb
speedtest.tyo11.jp.leaseweb.net|东京|Leaseweb
speedtest.fra1.de.leaseweb.net|法兰克福|Leaseweb
speedtest.ams2.nl.leaseweb.net|阿姆斯特丹|Leaseweb
ams.speedtest.clouvider.net|阿姆斯特丹|Clouvider
speedtest.lon12.uk.leaseweb.net|伦敦|Leaseweb
lon.speedtest.clouvider.net|伦敦|Clouvider
speedtest.lax12.us.leaseweb.net|洛杉矶|Leaseweb
speedtest.sfo12.us.leaseweb.net|旧金山|Leaseweb
speedtest.sea11.us.leaseweb.net|西雅图|Leaseweb
speedtest.dal13.us.leaseweb.net|达拉斯|Leaseweb
speedtest.chi11.us.leaseweb.net|芝加哥|Leaseweb
speedtest.nyc1.us.leaseweb.net|纽约|Leaseweb
speedtest.mia11.us.leaseweb.net|迈阿密|Leaseweb
speedtest.mtl2.ca.leaseweb.net|蒙特利尔|Leaseweb
"

# 自动挑选对端：先按 RTT 排序, 再逐个验证 iperf3 真的能用（公共服务器常年占线）
auto_pick_peer(){
  local best="" cand rtt name line
  info "自动选择测速对端（测的是本机端口上限, 越近越准）…" >&2
  # 并行 ping 全部节点. 串行时 17 个节点 × 最长 4 秒 = 最坏 68 秒, 用户干等.
  local sorted="" prov tmpd
  tmpd=$(mktemp -d)
  while IFS='|' read -r cand name prov; do
    [ -z "$cand" ] && continue
    ( r=$(ping -c 2 -q -W 2 "$cand" 2>/dev/null | awk -F'/' '/rtt|round-trip/{printf "%.0f", $5}')
      [ -n "$r" ] && echo "$r $cand $name $prov" > "$tmpd/$cand" ) &
  done <<< "$PEER_POOL"
  wait
  sorted=$(cat "$tmpd"/* 2>/dev/null); rm -rf "$tmpd"
  [ -n "$sorted" ] || { echo ""; return 1; }
  # RTT 分级：sweep 测的是本机端口上的限速器, 对端越近越准.
  #   ≤ideal  最佳, 链路干扰可忽略
  #   ≤accept 可用, 但要提醒用户结果可能偏保守
  #   >accept 拒绝, 宁可失败也不给错误结论
  # 早期只有一个 60ms 硬阈值, 结果香港机器上新加坡 61ms 被卡掉、整个流程失败 —— 太死板.
  local ideal="${NETTUNE_PEER_IDEAL_RTT:-50}"
  local accept="${NETTUNE_PEER_MAX_RTT:-100}"
  local fallback="" fallback_rtt=""
  while read -r rtt cand name prov; do
    [ -z "$cand" ] && continue
    if [ "$rtt" -gt "$accept" ] 2>/dev/null; then
      printf '  %-34s %-10s %-10s RTT %-6s %s\n' "$cand" "$name" "$prov" "${rtt}ms" "too far, skipped" >&2
      continue
    fi
    printf '  %-34s %-10s %-10s RTT %-6s ' "$cand" "$name" "$prov" "${rtt}ms" >&2
    # 先探端口, 把"根本不跑 iperf3/被墙"和"跑着但占线"分开 ——
    # 早期两者都报"占线", 用户完全看不出真实原因
    if ! timeout 6 bash -c "cat < /dev/null > /dev/tcp/$cand/5201" 2>/dev/null; then
      echo "port closed" >&2; continue
    fi
    # 没装 iperf3 时无法做占线探测（iperf3 要等确认之后才装）,
    # 降级成"端口通就算可用". 选错了也不致命 —— run_iperf 本身会换端口重试.
    if ! command -v iperf3 >/dev/null 2>&1; then
      printf '  %-34s %-6s %-10s RTT %-6s %s\n' "$cand" "$loc" "$prov" "${rtt}ms" "$(_c '0;32' 'reachable (port 5201)')" >&2
      echo "$cand:5201"; return 0
    fi
    # 这些公共节点都开 5201-5210 十个 iperf3 实例（公共列表里标的就是端口范围）.
    # 早期只试 5201, 等于放着 9 个空闲实例不用去跟全世界抢一个, 动不动就"占线".
    local gp="" try
    for try in 5201 5202 5203 5204 5205 5206 5207 5208 5209 5210; do
      if timeout 25 iperf3 -c "$cand" -p "$try" -t 3 -P 1 >/dev/null 2>&1; then gp="$try"; break; fi
    done
    if [ -n "$gp" ]; then
      if [ "$rtt" -le "$ideal" ] 2>/dev/null; then
        echo "${green}available${plain} (port $gp)" >&2; best="$cand:$gp"; break
      fi
      echo "available (port $gp, distant — held as fallback)" >&2
      [ -z "$fallback" ] && { fallback="$cand:$gp"; fallback_rtt="$rtt"; }
    else
      echo "all 10 ports busy" >&2
    fi
    sleep 2
  done <<< "$(echo "$sorted" | sort -n)"

  if [ -z "$best" ] && [ -n "$fallback" ]; then
    best="$fallback"
    echo >&2
    warn "最近的可用对端是 ${fallback_rtt}ms（理想是 ${ideal}ms 以内）." >&2
    warn "距离越远, 链路本身的丢包抖动越会混进测量, 拐点可能偏保守." >&2
    warn "结果仍然可用, 只是可能没榨到极限." >&2
  fi

  if [ -z "$best" ]; then
    warn "没找到 ${accept}ms 以内且空闲的公共测速服务器." >&2
    warn "公共服务器一次只接一个测试, 等几分钟再试通常就有了." >&2
    warn "或者自己开一台近处的机器跑 iperf3 -s, 然后用 --peer 指定." >&2
    return 1
  fi
  echo "$best"
}

# 验证对端路径是否干净. RTT 只是代理指标 —— 真正要的是路径没有丢包干扰测量.
# 用标称带宽的 40% 跑一次：这个速率远低于任何限速器, 此时还有明显重传,
# 就说明是链路本身在丢包, 拿它测拐点必然测偏.
validate_peer(){
  local peer="$1" nominal="$2" iface="$3"
  local rate=$(( nominal * 40 / 100 )); [ "$rate" -lt 20 ] && rate=20
  local saved=0; [ -x "$QDISC_SCRIPT" ] && saved=1
  tc qdisc del dev "$iface" root 2>/dev/null
  tc qdisc add dev "$iface" root fq maxrate "${rate}mbit" 2>/dev/null
  local res rt
  for _ in 1 2; do res=$(run_iperf "$peer" 8 2); [ -n "$res" ] && break; sleep 5; done
  tc qdisc del dev "$iface" root 2>/dev/null
  [ "$saved" = 1 ] && "$QDISC_SCRIPT" >/dev/null 2>&1 || tc qdisc add dev "$iface" root fq 2>/dev/null
  [ -n "$res" ] || { echo "unreachable"; return 1; }
  local gp; gp=$(echo "$res" | awk '{print $1}'); rt=$(echo "$res" | awk '{print $2}')
  # 对端连 40% 速率都跑不到, 说明它本身就比本机慢, 拿它测限速器毫无意义.
  # 早期只看重传不看吞吐, 结果对端只能跑 110Mbps 也被判为"路径干净"放行.
  if awk -v g="$gp" -v r="$rate" 'BEGIN{exit !(g < r*0.7)}' 2>/dev/null; then
    echo "slow:$gp/$rate"; return 1
  fi
  # 低速率下丢包率应该接近 0. 同样不能用绝对次数 —— 一台 10G 机在 40% 速率下
  # 重传 56 次（丢包率 0.0022%）被判成 "Link is lossy", 纯属误报.
  # 这里比 sweep 更严（0.05% vs 0.1%）, 因为跑的是 40% 速率, 本就不该丢包.
  local lp; lp=$(loss_pct "$rt" "$gp" 8)
  if awk -v l="$lp" 'BEGIN{exit !(l > 0.05)}' 2>/dev/null; then echo "dirty:${rt}(${lp}%)"; return 1; fi
  echo "clean:$rt"
}

# 曾用它清"超前输入"防止杂散回车误答, 但它会把管道/脚本喂进来的合法输入
# 一起吃掉（实测卡在带宽提示不动）, 手速快的用户也会中招.
# 主操作默认值改成 y 之后, 杂散回车本身已无害, 所以不再调用.
flush_input(){ :; }

ask(){  # ask "问题" "默认值"  -> 回显用户输入或默认值
  local q="$1" d="${2:-}" a
  if [ -n "$d" ]; then printf '%s [%s]: ' "$q" "$d" >&2; else printf '%s: ' "$q" >&2; fi
  read -r a </dev/tty || a=""
  echo "${a:-$d}"
}

# confirm "问题" [默认]  -> 0=是 1=否. 默认 y 时空回车即同意.
# 主操作（如"开始调优？"）必须默认 y —— 用户就是为这个来的,
# 一个杂散回车不该让整个流程静默取消.
confirm(){
  local d="${2:-n}" a p
  [ "$d" = y ] && p="(Y/n)" || p="(y/N)"
  a=$(ask "$1 $p" "$d")
  [[ "$a" =~ ^[Yy] ]]
}

# 框宽固定 48 列. 每行按显示宽度补齐后再包边框 ——
# 手写空格对不齐, 因为 CJK 占 2 列而框线字符占 1 列.
BOX_W=56
_row(){ # _row "<内容>" [颜色代码]
  local txt="$1" col="${2:-}" pad
  pad=$(( BOX_W - $(_dispw "$txt") ))
  [ "$pad" -lt 0 ] && pad=0
  if [ -n "$col" ]; then printf '│\033[%sm%s\033[0m%*s│\n' "$col" "$txt" "$pad" ""
  else printf '│%s%*s│\n' "$txt" "$pad" ""; fi
}
_sep(){ printf '│'; printf '─%.0s' $(seq $BOX_W); printf '│\n'; }
_top(){ printf '╔'; printf '─%.0s' $(seq $BOX_W); printf '╗\n'; }
_bot(){ printf '╚'; printf '─%.0s' $(seq $BOX_W); printf '╝\n'; }

# 菜单条目：中文名、英文名、耗时三列各自按显示宽度补齐.
# 手写空格必然错位 —— 中文占 2 列,"~10 min" 这种右列一长就把右边框顶出去.
_item(){ # _item <编号> <中文> <英文> [耗时]
  _row "$(printf '  %s. %s %s %s ' "$1" "$(_pad "$2" 10)" "$(_pad "$3" 30)" "$(_rpad "${4:-}" 8)")"
}

banner(){
  local iface cc shaper ram cores tuned
  iface=$(detect_iface)
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  shaper=$(tc class show dev "$iface" 2>/dev/null | grep -oE 'rate [0-9]+[MG]bit' | head -1 | awk '{print $2}')
  ram=$(detect_ram_mb); cores=$(detect_cores)
  [ -f "$SYSCTL_FILE" ] && tuned="Tuned" || tuned="Stock"
  clear 2>/dev/null || true
  echo
  _top
  _row "$(printf '  tcpfit - VPS TCP Optimization%s ' "$(_rpad "v$VERSION" 23)")" '0;32'
  _row "  0. Exit"
  _sep
  _item 1 "一键调优" "Auto-tune (recommended)"   "~10 min"
  _item 2 "基础调优" "Base tuning only"          "~1 min"
  _item 3 "拐点测试" "Policer sweep"             "~8 min"
  _item 4 "加 swap"  "Add swap (low-memory box)"
  _sep
  _item 5 "查看状态" "Status"
  _item 6 "端口验证" "Verify port capability"    "~1 min"
  _item 7 "回滚改动" "Rollback all changes"
  _bot
  printf "  %-9s %s core / %s MB / %s\n" "Machine" "$cores" "$ram" "$(uname -r)"
  printf "  %-9s cc=%s  shaper=%s  " "Network" "${cc:-?}" "${shaper:-none}"
  [ "$tuned" = Tuned ] && printf "${green}%s${plain}\n" "$tuned" || printf "${yellow}%s${plain}\n" "$tuned"
}

# 一键全自动.
# 设计原则：所有要用户回答的东西集中在最前面（3 个问题）, 确认之后一路跑到底不再打断；
# 执行阶段的日志用英文（都是参数名和数值, 中英混排反而看不清）, 结论用中文.
wizard(){
  WIZARD=1
  local ram; ram=$(detect_ram_mb)
  echo
  echo "  ── 一键调优 ──"
  echo
  rule
  echo "  开始前的说明"
  echo
  echo "  改动前会把当前配置完整备份到"
  echo "      $(_c '1' "$SNAPSHOT")"
  echo "  包含拥塞控制、全部缓冲区参数、qdisc、路由等原始值."

  # iperf3 单独放在最前面确认 —— 两个原因:
  #   1) 装包是会改系统的操作, 不该在用户点头之前做
  #   2) 选对端那一步要用 iperf3 做占线探测, 所以必须在三个问题之前就位
  local HAVE_IPERF3=1 QN=3
  if command -v iperf3 >/dev/null 2>&1; then
    echo "  iperf3 已经安装 $(iperf3 --version 2>/dev/null | awk 'NR==1{print $2}')"
  else
    echo "  确认带宽之前, tcpfit 需要安装 iperf3 才可以正常运行."
    echo
    if confirm "  安装？" y; then
      echo "    ────────────────────────────────────────"
      if   command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y iperf3
      elif command -v dnf     >/dev/null; then dnf install -y iperf3
      elif command -v yum     >/dev/null; then yum install -y epel-release; yum install -y iperf3
      elif command -v apk     >/dev/null; then apk add iperf3
      else warn "认不出包管理器, 请手动安装 iperf3"; fi
      echo "    ────────────────────────────────────────"
    fi
    if command -v iperf3 >/dev/null 2>&1; then
      ok "iperf3 $(iperf3 --version 2>/dev/null | awk 'NR==1{print $2}') 已就绪"
    else
      # 不中止 —— 基础调优(BBR/缓冲区/起步)完全不依赖 iperf3, 那也是收益最大的一部分.
      # 少掉的是: 实测带宽、扫拐点、验证吞吐.
      HAVE_IPERF3=0; QN=2
      echo
      warn "没有 iperf3, 只能做基础调优:"
      warn "  不能实测带宽(要你手填)、不能扫限速器拐点、不能验证吞吐."
      warn "  基础调优本身照做, 那是收益最大的一部分."
    fi
  fi

  # ── 1/3 带宽 ────────────────────────────────────────────────────────────
  step "1/${QN}  确认带宽"
  echo
  echo "    你这台机器的带宽是多少 Mbps？常见 100 / 200 / 300 / 500 / 1000."
  echo
  printf "    %s建议手动输入. %s回车会在执行阶段现场实测一个估值……\n" "$yellow" "$plain"
  if [ "$HAVE_IPERF3" = 1 ]; then
    echo "    跳过扫描. 填 0 表示不做整形（端口没有限速器时选这个）."
    echo "    已经知道限速值？输入 m 跳过拐点扫描直接指定"
  fi
  echo
  # MANUAL_RATE 的三种状态：""=正常扫描 / 数字=直接按该值整形 / "off"=完全不整形
  local bw MANUAL_RATE=""
  while true; do
    bw=$(ask "  带宽 Mbps" "")
    case "$bw" in
      "")      [ "$HAVE_IPERF3" = 0 ] && { warn "  没有 iperf3, 无法实测, 请手动填一个数字"; continue; }
               bw=auto; break ;;                       # 回车 → 执行阶段实测
      0)       MANUAL_RATE=off; bw=auto; break ;;      # 0 → 不整形, 带宽仍需实测
      m|M)                                             # m → 跳到限速值那一问
        while true; do
          MANUAL_RATE=$(ask "  限速值 Mbit" "")
          [ -z "$MANUAL_RATE" ] && { warn "  请填一个数字, 0 表示不做整形"; continue; }
          [ "$MANUAL_RATE" = 0 ] && { MANUAL_RATE=off; bw=auto; break; }
          if { [ "$MANUAL_RATE" -gt 0 ] && [ "$MANUAL_RATE" -le 100000 ]; } 2>/dev/null; then
            bw="$MANUAL_RATE"; break                   # 限速值同时作为算 BDP 的带宽基准
          fi
          warn "  请输入一个正整数（单位 Mbit）, 或 0 表示不做整形"
        done
        break ;;
      *)
        { [ "$bw" -gt 0 ] && [ "$bw" -le 100000 ]; } 2>/dev/null && break
        warn "  请输入一个正整数（单位 Mbps）, 或 m / 0" ;;
    esac
  done

  # ── 2/3 对端 ────────────────────────────────────────────────────────────
  # 没有 iperf3 就没有对端可言, 整段跳过, 且强制不做整形
  local peer="(不需要)"
  if [ "$HAVE_IPERF3" = 0 ]; then
    MANUAL_RATE="${MANUAL_RATE:-off}"
  else
  step "2/${QN}  确认测速对端"
  echo
  echo "    拐点扫描需要一台对端机器跑 iperf3 服务端."
  echo
  echo "    A) 直接回车 —— 用公共节点（默认）"
  echo "       由以下厂商免费提供, 测试流量会发往它们："
  echo "           Leaseweb / Clouvider / OVH"
  echo "           完整列表见 iperf3serverlist.net"
  echo
  echo "    B) 用你自己的另一台机器"
  echo "       在那台机器上执行这两条："
  printf "           %sapt install -y iperf3%s    # 装 iperf3；已装过会跳过, 不会重装\n" "$green" "$plain"
  printf "           %siperf3 -s%s                # 启动服务端, 默认监听 5201 端口\n" "$green" "$plain"
  echo "       然后在下面填那台机器的 IP, 例如  1.2.3.4"
  printf "       %s本脚本默认连 5201 端口%s；对端换了端口的话填  IP:端口  形式. \n" "$yellow" "$plain"
  echo "       对端要选离本机近的."
  echo
  peer=$(ask "  对端 IP / 域名（回车=公共节点）" "")
  if [ -z "$peer" ]; then
    local picked; picked=$(auto_pick_peer) || die "公共测速服务器暂时都不可用, 稍后再试" 2
    peer="${picked%:*}"; PEER_PORT="${picked##*:}"
  else
    case "$peer" in *:*) PEER_PORT="${peer##*:}"; peer="${peer%:*}" ;; esac
  fi
  fi

  # ── 3/3 用途 ────────────────────────────────────────────────────────────
  step "${QN}/${QN}  机器用途"
  echo
  echo "    1) 代理 / 加速        并发连接多, 缓冲区取保守值（最常见）"
  echo "    2) 大文件传输 / 备份  少数大流, 缓冲区取激进值"
  echo
  local rc role
  rc=$(ask "  选择" "1")
  case "$rc" in 2) role=bulk ;; *) role=proxy ;; esac

  # ── 确认 ────────────────────────────────────────────────────────────────
  echo
  rule
  echo "  确认"
  echo
  if [ "$bw" = auto ]; then
    _conf "带宽" "自动实测（执行阶段测）"
  elif [ -n "$MANUAL_RATE" ]; then
    _conf "带宽" "${bw} Mbps"                      # 手填时余量无意义, 不显示
  else
    _conf "带宽" "${bw} Mbps        整形安全余量 $(calc_margin "$bw") Mbit"
  fi
  case "$MANUAL_RATE" in
    "")  _conf "整形" "实测拐点后自动决定" ;;
    off) _conf "整形" "不做整形" ;;
    *)   _conf "整形" "${MANUAL_RATE} Mbit" ;;
  esac
  [ "$HAVE_IPERF3" = 1 ] && _conf "对端" "${peer}:${PEER_PORT}"
  _conf "用途" "$([ "$role" = bulk ] && echo '大文件传输 / 备份' || echo '代理 / 加速')"
  if [ "$HAVE_IPERF3" = 1 ]; then _conf "iperf3" "$(iperf3 --version 2>/dev/null | awk 'NR==1{print $2}')"
  else _conf "iperf3" "无, 只做基础调优"; fi
  _conf "安装位置" "$SELF_PATH"
  echo
  if [ -n "$MANUAL_RATE" ]; then _conf "预计耗时" "约 1 分钟"
  else                              _conf "预计耗时" "约 10 分钟"; fi
  if [ -n "$MANUAL_RATE" ]; then _conf "预计流量" "很少"
  elif [ "$bw" = auto ]; then   _conf "预计流量" "带宽实测后才能估"
  else                          _conf "预计流量" "约 $(estimate_traffic_gb "$bw") GB"; fi
  rule
  confirm "  开始调优？" y || { info "已取消, 未做任何改动"; return 0; }

  # ══ 执行阶段：全自动, 不再有任何提问 ══════════════════════════════════
  traffic_mark
  printf '\n  %s════ Running ═══════════════════════════════════════════%s\n' "$bold" "$plain"

  printf '\n  %s[1/5] Base tuning%s\n' "$bold" "$plain"
  if [ "$bw" = auto ]; then
    info "Probing bandwidth (4 streams + pacing, ~15s)..."
    bw=$(probe_bandwidth "$peer" "$(detect_iface)") || die "bandwidth probe failed" 2
    ok "Measured ~${bw} Mbps"
  fi
  cmd_tune --role "$role" --bw "$bw" || die "base tuning failed"

  # 手动指定了限速值（或选了不整形）→ 路径验证和拐点扫描都没有意义, 直接跳到应用
  if [ -n "$MANUAL_RATE" ]; then
    printf '\n  %s[2/3] Apply shaping%s\n' "$bold" "$plain"
    if [ "$MANUAL_RATE" = off ]; then
      cmd_shape --off
      rate=""
    else
      cmd_shape --rate "$MANUAL_RATE"
      rate="$MANUAL_RATE"; knee=""; margin=""
    fi
    printf '\n  %s[3/3] Verify%s\n' "$bold" "$plain"
    command -v iperf3 >/dev/null && verify_measure "$peer" || warn "no iperf3, throughput not verified"
    wizard_result "$bw" "$rate" "$knee" "$margin" "$ram"
    return 0
  fi

  printf '\n  %s[2/5] Path quality check%s\n' "$bold" "$plain"
  info "Probing at 40% of ${bw} Mbps -- far below any policer."
  echo "    Retransmits at this rate would mean the link itself is lossy."
  local v; v=$(validate_peer "$peer" "$bw" "$(detect_iface)")
  case "$v" in
    clean:*) ok "Path clean (retrans ${v#clean:})" ;;
    # 链路本身丢包只会让拐点读低一点, 数据仍然有效 —— 警告后照跑, 不打断
    dirty:*) warn "Link is lossy (retrans ${v#dirty:}). The knee may read low; sweep continues." ;;
    slow:*)  warn "Peer only reached ${v#slow:} Mbps. Sweep will decide whether to abort." ;;
    *)       warn "Path check failed; continuing anyway." ;;
  esac

  printf '\n  %s[3/5] Policer sweep%s\n' "$bold" "$plain"
  cmd_sweep --peer "$peer" --nominal "$bw" || warn "sweep failed, skipping shaping"

  if [ -f "$STATE_DIR/sweep.result" ]; then
    knee=$(awk -F= '/^KNEE/{print $2}'      "$STATE_DIR/sweep.result")
    rate=$(awk -F= '/^RECOMMEND/{print $2}' "$STATE_DIR/sweep.result")
    [ -n "$knee" ] && [ -n "$rate" ] && margin=$(( knee - rate ))
  fi

  printf '\n  %s[4/5] Apply shaping%s\n' "$bold" "$plain"
  if [ -n "$rate" ]; then cmd_shape --rate "$rate"; else warn "no knee measured, shaping skipped"; fi

  printf '\n  %s[5/5] Verify%s\n' "$bold" "$plain"
  command -v iperf3 >/dev/null && verify_measure "$peer" || warn "no iperf3, throughput not verified"

  wizard_result "$bw" "$rate" "$knee" "$margin" "$ram"
}

# 结果段落. 正常流程和"手动指定整形值"两条路径共用, 避免两份重复的排版代码.
wizard_result(){   # wizard_result <带宽> <整形值> <拐点> <余量> <内存MB>
  local bw="$1" rate="$2" knee="$3" margin="$4" ram="$5"
  printf '\n  %s════ 结果 ══════════════════════════════════════════════%s\n' "$bold" "$plain"
  echo
  if [ -n "$knee" ]; then
    _conf "实测端口上限" "${knee} Mbit"
    _conf "安全余量"     "${margin} Mbit（按 ${bw}M 档位）"
    _conf "已应用整形"   "${rate} Mbit"
    echo
  elif [ -n "$rate" ]; then
    _conf "已应用整形"   "${rate} Mbit"
    echo
  else
    _conf "整形"         "未设置"
    echo
  fi
  verify_verdict "$rate"
  traffic_report
  echo
  echo "  本次改动和快照位置"
  echo "      $SYSCTL_FILE"
  [ -n "$rate" ] && echo "      $QDISC_UNIT"
  echo "      $SNAPSHOT"

  # 小内存且没 swap 才提. 内存够用或已有 swap 就完全不出现这一段.
  if [ "$ram" -le 1024 ] && ! swapon --show 2>/dev/null | grep -q .; then
    step "swap"
    echo
    echo "    本机 ${ram} MB 内存且没有 swap. 跑代理时 TCP 缓冲区可能撑爆内存,"
    echo "    代理进程被系统杀掉."
    echo
    confirm "  创建 2G swap？" y && cmd_harden --swap 2G
  fi
  echo
  ok "调优完成."
}

menu_loop(){
  need_root
  migrate_legacy
  self_install
  while true; do
    banner
    echo
    local c; c=$(ask "  请选择 / Select [0-7]" "1")
    echo
    case "$c" in
      1) wizard ;;
      2) local r; r=$(ask "  用途 1) 代理/加速  2) 大文件传输" "1")
         local role=proxy; [ "$r" = 2 ] && role=bulk
         local b; b=$(ask "  带宽 Mbps (回车=自动探测)" "")
         if [ -n "$b" ]; then cmd_tune --role "$role" --bw "$b"
         else
           local p; if p=$(auto_pick_peer); then PEER_PORT="${p##*:}"; cmd_tune --role "$role" --bw auto --peer "${p%:*}"
           else warn "No peer available; specify bandwidth manually"; fi
         fi ;;
      3) local p; if p=$(auto_pick_peer); then
           PEER_PORT="${p##*:}"; p="${p%:*}"
           local b; b=$(ask "  带宽 Mbps" "")
           cmd_sweep --peer "$p" --nominal "$b"
           local rate; rate=$(awk -F= '/^RECOMMEND/{print $2}' "$STATE_DIR/sweep.result" 2>/dev/null)
           [ -n "$rate" ] && confirm "  应用 ${rate}Mbit 整形？" y && cmd_shape --rate "$rate"
         else warn "No peer available"; fi ;;
      4) if swapon --show 2>/dev/null | grep -q .; then
           info "已有 swap: $(free -h | awk '/Swap/{print $2}'), 回车跳过；要再建就输入数字"
           local sg; sg=$(ask "  swap 大小 GB (1-20, 回车跳过)" ""); [ -n "$sg" ] && cmd_harden --swap "$sg"
         else
           echo "  输入 1-20 的数字（单位 GB）, 推荐 1-4；回车 = 2；输入 0 = 不创建."
           local sg; sg=$(ask "  swap 大小 GB" "2"); [ "$sg" != 0 ] && cmd_harden --swap "$sg"
         fi ;;
      5) cmd_status ;;
      6) local p; if p=$(auto_pick_peer); then PEER_PORT="${p##*:}"; cmd_verify --peer "${p%:*}"; else cmd_verify; fi ;;
      7) confirm "  确定回滚全部改动？" && cmd_rollback ;;
      0) exit 0 ;;
      *) warn "Invalid selection" ;;
    esac
    echo
    printf "  ${yellow}Press any key to return to menu...${plain}"
    read -rsn1 </dev/tty 2>/dev/null || read -r </dev/tty 2>/dev/null || true
    echo
  done
}

# ── 入口 ────────────────────────────────────────────────────────────────────
usage(){ sed -n '2,20p' "$0" | sed 's/^# \?//'; }

case "${1:-}" in
  detect)   shift; cmd_detect "$@" ;;
  tune)     shift; cmd_tune "$@" ;;
  probe)    shift; cmd_probe "$@" ;;
  sweep)    shift; cmd_sweep "$@" ;;
  shape)    shift; cmd_shape "$@" ;;
  harden)   shift; cmd_harden "$@" ;;
  verify)   shift; cmd_verify "$@" ;;
  status)   shift; cmd_status "$@" ;;
  rollback) shift; cmd_rollback "$@" ;;
  version)  echo "tcpfit $VERSION" ;;
  menu)     shift; menu_loop ;;
  "")       menu_loop ;;
  -h|--help|help) usage ;;
  *) die "未知命令: $1（-h 看用法）" ;;
esac
