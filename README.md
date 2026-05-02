# incudal-rfw

Incudal RFW 是一个面向 Linux 宿主机的 IPv4 入站防火墙，基于 eBPF/XDP
在网卡入口处直接丢弃不希望进入宿主机的流量。本项目主要服务于 Incus
切机/托管场景，重点用于识别和阻断常见节点、代理、VPN 协议。

本项目主要参考并基于
[narwhal-cloud/rfw](https://github.com/narwhal-cloud/rfw)
进行改进，详见 [鸣谢](#鸣谢)。

## 功能概览

- 仅处理 IPv4 入站流量，暂不处理 IPv6。
- 使用 XDP 在网卡入口处阻断流量，减少进入用户态和协议栈后的开销。
- 支持 GeoIP 黑名单、白名单、无 GeoIP 三种作用范围。
- 支持按协议特征识别常见节点协议，而不是单纯按端口阻断。
- 支持 SOCKS、VLESS TCP、VMess TCP、HY2、TUIC、QUIC、WireGuard、
  UDP 高熵加密流量、明文 HTTP、SMTP 发信滥用等规则。
- 提供测试部署脚本，可从 GitHub Release 下载产物并安装为 systemd 服务。

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
```

如果不指定 GeoIP 参数，协议规则会作用于所有来源。

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

不区分国家，强力阻断所有来源的节点协议：

```bash
sudo ./rfw --iface eth0 \
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

## 测试部署脚本

`rfw-test-deploy.sh` 用于在测试机器上快速部署 GitHub Release 产物。直接运行
脚本会进入中文交互菜单；带参数运行则保持命令行模式。它会：

1. 根据架构下载 Release 二进制；
2. 安装到 `/root/rfw/rfw`；
3. 写入 `/etc/systemd/system/rfw.service`；
4. 启动并设置开机自启；
5. 卸载时可一并清理脚本副本和当前脚本本身。

交互式菜单：

```bash
sudo bash rfw-test-deploy.sh
```

全局强力节点阻断：

```bash
sudo bash rfw-test-deploy.sh --iface eth0 --profile strong --geo-mode none --yes
```

测试 HY2 / 混淆 HY2：

```bash
sudo bash rfw-test-deploy.sh --iface eth0 --profile hy2 --geo-mode none
```

测试 TUIC：

```bash
sudo bash rfw-test-deploy.sh --iface eth0 --profile tuic --geo-mode none
```

测试 TCP 弱节点协议：

```bash
sudo bash rfw-test-deploy.sh --iface eth0 --profile tcp-node --geo-mode none
```

可选 profile：

```text
strong    QUIC、HY2、TUIC、VLESS、VMess、UDP-FET、SOCKS、WG、HTTP、Email 全开
hy2       重点测试 HY2 / 混淆 HY2 / UDP 滥用
tuic      重点测试 TUIC / 非 Web 端口 QUIC 代理
tcp-node  重点测试 VLESS / VMess / SOCKS / FET 这类 TCP 弱协议
baseline  基础节点阻断组合
manual    逐条规则交互选择
```

常用操作：

```bash
sudo bash rfw-test-deploy.sh --status
sudo bash rfw-test-deploy.sh --logs
sudo bash rfw-test-deploy.sh --block-logs
sudo bash rfw-test-deploy.sh --stats
sudo bash rfw-test-deploy.sh --restart
sudo bash rfw-test-deploy.sh --uninstall
```

注意：默认规则会附加 `--countries CN`。如果要测试所有来源都被拦截，请使用：

```bash
--geo-mode none
```

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

测试部署脚本默认从这里下载最新版：

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
