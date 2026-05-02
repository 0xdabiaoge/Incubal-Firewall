# incudal-rfw

Incudal RFW 是一个面向 Linux 宿主机的 IPv4 入站阻断工具。部署脚本默认使用
`nftables` / `iptables` 写入内核防火墙规则，保证 Debian / Ubuntu 上稳定启动；
高级模式仍可使用 eBPF/XDP 在网卡入口处做更细的协议识别。本项目主要服务于
Incus 切机/托管场景，重点用于阻断常见节点、代理、VPN 协议相关流量。

本项目主要参考并基于
[narwhal-cloud/rfw](https://github.com/narwhal-cloud/rfw)
进行改进，详见 [鸣谢](#鸣谢)。

## 功能概览

- 仅处理 IPv4 入站流量，暂不处理 IPv6。
- 部署脚本支持 `nftables`、`iptables/ipset`、`xdp` 三种后端。
- 默认使用内核防火墙后端，资源占用低，启动路径稳定。
- XDP 后端可在网卡入口处阻断流量，支持更细的 payload 协议识别。
- 支持 GeoIP 黑名单、白名单、无 GeoIP 三种作用范围。
- 支持按协议特征识别常见节点协议，而不是单纯按端口阻断。
- 支持 SOCKS、VLESS TCP、VMess TCP、HY2、TUIC、QUIC、WireGuard、
  UDP 高熵加密流量、明文 HTTP、SMTP 发信滥用等规则。
- 提供中文正式部署脚本，可从 GitHub Release 下载产物并安装为 systemd 服务。

## 规则说明

### 基础规则

```bash
--block-email          # 阻断 SMTP 滥用端口：25、26、465、587、2525
--block-http           # 阻断明文 HTTP 入站流量
--block-socks5         # 阻断 SOCKS4 / SOCKS4a / SOCKS5 入站流量
--block-wireguard      # 阻断 WireGuard UDP 流量
--block-all            # 阻断作用范围内的所有 IPv4 入站流量
```

### TCP 节点规则

```bash
--block-vless-tcp      # 尽力识别并阻断裸 VLESS over TCP
--block-vmess-tcp      # 阻断裸 VMess / TCP 高熵弱协议
--block-fet-strict     # 严格阻断 TCP 全加密高熵流量
--block-fet-loose      # 宽松 FET 模式，误伤更低，阻断更保守
```

说明：

- `--block-vless-tcp` 主要针对没有 TLS、Reality、WS、gRPC 外层伪装的纯 VLESS TCP。
- `--block-vmess-tcp` 是 VMess/raw TCP 专用开关。
- `--block-fet-strict` 也会覆盖很多 VMess、Shadowsocks、V2Ray 类 TCP 高熵弱协议。

### UDP / QUIC 节点规则

```bash
--block-quic           # 粗暴阻断可识别 QUIC，HY2 / TUIC / HTTP3 会一起被挡
--block-hysteria2      # 尽力阻断 HY2、混淆 HY2、暴力 UDP 行为
--block-tuic           # 尽力阻断 TUIC / 非 Web 端口 QUIC 代理
--block-udp-fet        # 阻断 UDP 高熵加密流量
```

说明：

- HY2 和 TUIC 都是 QUIC 方向的 UDP 节点协议，应用层内容加密，无法在 XDP
  首包层面做到 100% 精准区分。
- `--block-quic` 是最粗暴的 QUIC 总开关，会影响正常 HTTP/3。
- `--block-hysteria2` 更偏向 HY2 / obfs HY2 / UDP 高熵滥用场景。
- `--block-tuic` 更偏向非 Web 端口上的 TUIC/QUIC 代理流量。
- `--block-udp-fet` 不是阻断全部 UDP，而是阻断看起来像全加密随机流量的 UDP payload。

### GeoIP 作用范围

```bash
--countries CN,RU              # 黑名单模式：只对这些国家来源应用规则
--allow-only-countries US,JP   # 白名单模式：只允许这些国家，其余来源按规则阻断
--block-all-from CN,RU         # 快捷模式：阻断指定国家所有入站 IPv4 流量
--all-sources                  # 显式关闭默认 GeoIP 范围，对所有来源应用协议规则
```

如果不指定 GeoIP 参数，RFW 默认只对中国来源 `CN` 应用协议规则。只有显式指定
`--all-sources` 时，协议规则才会作用于所有来源。

### 其他参数

```bash
--iface eth0                   # 要挂载 XDP 的网卡，默认 eth0
--xdp-mode auto|skb|drv|hw     # XDP 附加模式，默认 auto
--log-port-access              # 记录端口访问统计
```

如果原生 XDP 挂载失败，可以优先尝试：

```bash
--xdp-mode skb
```

## 使用示例

只阻断来自中国的常见节点协议：

```bash
sudo ./rfw --iface eth0 \
  --countries CN \
  --block-socks5 \
  --block-vless-tcp \
  --block-vmess-tcp \
  --block-fet-strict \
  --block-wireguard \
  --block-hysteria2 \
  --block-tuic \
  --block-udp-fet
```

默认只针对中国来源，强力阻断常见节点协议：

```bash
sudo ./rfw --iface eth0 \
  --countries CN \
  --block-email \
  --block-http \
  --block-socks5 \
  --block-vless-tcp \
  --block-vmess-tcp \
  --block-fet-strict \
  --block-wireguard \
  --block-quic \
  --block-hysteria2 \
  --block-tuic \
  --block-udp-fet
```

阻断指定国家的所有 IPv4 入站：

```bash
sudo ./rfw --iface eth0 --block-all-from CN,RU
```

查看端口访问统计：

```bash
sudo ./rfw --iface eth0 --block-socks5 --log-port-access
sudo ./rfw stats
sudo ./rfw stats --port 443
sudo ./rfw stats --blocked-only
sudo ./rfw stats --group-by-port
```

## 正式部署脚本

`rfw-test-deploy.sh` 用于在 Debian / Ubuntu 宿主机上部署阻断规则。新版脚本不再把
XDP 作为唯一启动路径，而是提供三个后端：

- `nft`：推荐默认后端。使用 `nftables` + `systemd oneshot` 写入内核规则，资源占用低，启动稳定。
- `iptables`：兼容后端。使用 `iptables` + `ipset`，适合老系统或 `nftables` 不可用环境。
- `xdp`：高级后端。使用原 rfw eBPF/XDP 程序，支持 payload 深度协议识别，但依赖内核、网卡和 XDP 挂载能力。

防火墙后端支持稳定阻断 IP 来源范围、国家 CIDR、TCP/UDP 端口和全入站规则；VLESS、
VMess、FET、UDP-FET 等 payload 深度识别只有 `xdp` 后端支持。

脚本会：

1. 自动安装缺失依赖；
2. 下载国家 IPv4 CIDR 数据；
3. 生成 `nftables` 或 `iptables/ipset` 规则，或下载 Release 二进制并启动 XDP；
4. 写入 `/etc/systemd/system/rfw.service`；
5. 启动、设置开机自启并验证规则是否生效；
6. 提供规则开关、日志、状态查看、重启和卸载功能。

打开控制台：

```bash
sudo bash rfw-test-deploy.sh
```

控制台主要功能：

- 安装 / 重新部署：选择 `nft`、`iptables` 或 `xdp` 后端并应用规则。
- 规则开关管理：逐条启用或关闭阻断规则，保存后自动重写 systemd 并重启生效。
- 查看当前配置：展示后端、作用范围、规则和实际内核规则。
- 查看运行日志。
- 重启服务或卸载并清理规则。

默认策略：

- 默认后端为 `auto`，优先使用 `nft`，缺失时使用 `iptables`。
- 默认只对中国来源 `CN` 生效。
- 默认启用推荐端口阻断规则：邮件、HTTP、SOCKS、WireGuard、QUIC、HY2、TUIC。
- payload 深度识别规则默认不在防火墙后端生成；需要这些能力时使用 `--backend xdp`。
- `全入站阻断` 默认不开，需要手动开启。

SS / Shadowsocks 说明：

- SS TCP 没有单独按钮，主要由 `SS/TCP-FET 严格` 这条规则覆盖。
- SS UDP 没有单独按钮，主要由 `SS UDP/UDP-FET` 这条规则覆盖。
- `SOCKS 代理` 指的是 SOCKS4/SOCKS5 协议本身，不等同于 Shadowsocks。

规则开关支持批量输入：

```text
3 7 8          切换 SOCKS、QUIC、HY2
1-4            切换 1 到 4 号规则
mail hy2 tuic  切换邮件、HY2、TUIC
a              全部开启
n              全部关闭
d              恢复推荐规则
s              保存并应用
0              返回主菜单
```

直接使用默认推荐规则部署：

```bash
sudo bash rfw-test-deploy.sh --install --backend nft --countries CN --yes
```

兼容老系统部署：

```bash
sudo bash rfw-test-deploy.sh --install --backend iptables --countries CN --yes
```

使用 XDP 深度识别部署：

```bash
sudo bash rfw-test-deploy.sh --install --backend xdp --iface eth0 --xdp-mode skb --countries CN --yes
```

直接传入完整 RFW 参数：

```bash
sudo bash rfw-test-deploy.sh --backend xdp --iface eth0 --rules "--block-socks5 --block-hysteria2 --countries CN --log-port-access" --yes
```

只阻断中国来源是默认行为。如果要测试所有来源都被拦截，请在控制台的作用范围中选择
“不区分国家”，或者命令行使用：

```bash
sudo bash rfw-test-deploy.sh --backend nft --geo-mode none --yes
```

常用操作：

```bash
sudo bash rfw-test-deploy.sh --status
sudo bash rfw-test-deploy.sh --logs
sudo bash rfw-test-deploy.sh --restart
sudo bash rfw-test-deploy.sh --uninstall
```

端口访问统计仅 XDP 后端支持：

```bash
sudo /root/rfw/rfw stats --blocked-only
sudo /root/rfw/rfw stats --group-by-port
sudo /root/rfw/rfw stats --port 443
```

脚本会把 `--geo-mode none` 转换为 RFW 的 `--all-sources` 参数。

## 编译

Ubuntu 依赖安装：

```bash
sudo apt update
sudo apt install -y build-essential curl git musl-tools gcc-aarch64-linux-gnu clang llvm libelf-dev
curl https://sh.rustup.rs -sSf | sh
source ~/.cargo/env

rustup toolchain install stable
rustup toolchain install nightly --component rust-src
rustup target add --toolchain stable x86_64-unknown-linux-musl
rustup target add --toolchain stable aarch64-unknown-linux-musl
cargo install bpf-linker --locked
```

编译 x86_64：

```bash
CC=musl-gcc cargo build --package rfw --release --target x86_64-unknown-linux-musl
```

编译 aarch64：

```bash
CC=aarch64-linux-gnu-gcc \
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=aarch64-linux-gnu-gcc \
cargo build --package rfw --release --target aarch64-unknown-linux-musl
```

整理产物：

```bash
mkdir -p artifacts
cp target/x86_64-unknown-linux-musl/release/rfw artifacts/rfw-x86_64-unknown-linux-musl
cp target/aarch64-unknown-linux-musl/release/rfw artifacts/rfw-aarch64-unknown-linux-musl
chmod +x artifacts/rfw-*
cd artifacts
sha256sum rfw-* > checksums.txt
```

## GitHub Release 自动构建

当前 GitHub Actions 会在推送 `v*` tag 时自动构建 Release 产物。

```bash
git tag v1.0.1
git push origin main
git push origin v1.0.1
```

预期 Release 产物：

```text
rfw-x86_64-unknown-linux-musl
rfw-aarch64-unknown-linux-musl
checksums.txt
```

正式部署脚本默认从这里下载最新版：

```text
https://github.com/0xdabiaoge/incudal-rfw/releases/latest/download
```

## 技术说明

- 当前只解析 IPv4，不处理 IPv6。
- 检测方式是 XDP 单包 DPI + 轻量连接跟踪，不做完整 TCP 流重组。
- `--block-quic` 会阻断所有可识别 QUIC，可能影响正常 HTTP/3。
- HY2 / TUIC 拆分属于尽力识别，因为二者都基于 QUIC，应用层内容加密。
- `--block-udp-fet` 不会阻断全部 UDP，只阻断高熵加密特征明显的 UDP payload。
- VLESS / VMess TCP 规则主要针对裸 TCP 版本；如果套 TLS、Reality、WS、gRPC，
  需要进一步做外层协议/行为检测。

## GeoIP 数据源

运行时会从以下项目下载国家 CIDR 列表：

```text
https://github.com/Loyalsoldier/geoip
```

## 鸣谢

本项目主要参考并基于
[narwhal-cloud/rfw](https://github.com/narwhal-cloud/rfw)
进行改进。感谢原项目提供的 eBPF/XDP 防火墙基础实现和工程思路。

同时感谢 Aya 生态对 Rust eBPF 开发的支持，以及 GeoIP 数据源项目提供的国家
IP 段数据。

## 许可证

本项目保留原有授权结构：

- 用户态代码：MIT OR Apache-2.0
- eBPF 组件：Dual MIT/GPL
