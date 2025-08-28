# Seisa Magisk 模块（tproxy 优先）

功能

- 以 tproxy 为主实现透明代理（支持 TCP/UDP，包括 QUIC 在内但取决于内核/设备对 UDP TPROXY 的支持）
- 支持 fakeip + hijack-dns，用于在无法通过 sniff 获取域名信息的 UDP/QUIC 场景下实现域名分流
- 自动将 config.json 中 declared "server" 主机解析为 IP 并加入 ipset，以避免 sing-box 与其 outbound 服务器之间形成代理环路
- 支持 IPv6（若设备内核与 ip6tables 支持 IPv6 tproxy）
- 自动更新脚本从 SagerNet/sing-box Releases 下载最新适用于 Android arm64 的包（可选，支持 GitHub token）

注意与建议

- DNS 与 fakeip：
    - 若想让 rule_set（域名分流）在 UDP/QUIC 上也可靠工作，建议使用 hijack-dns + fakeip（当前 config.json 已启用 fakeip
      的示例范围）
    - 模块会尝试把系统 DNS (53) 捕获到 sing-box（通过 TPROXY），并由 sing-box 的 hijack-dns 处理（请验证 sing-box 的 DNS
      相关监听/行为，某些场景需要额外的 dns inbound）
- 避免回路（必须）：
    - 模块会解析 config.json 中的 outbound server 主机名并把解析到的 IP 写入 ipset（或直接放入 iptables），以确保 sing-box
      到其远端节点的连接不会被再次重定向回 sing-box
    - 由于远端服务器 IP 可能变化（CDN），建议启用定期刷新（可通过触发 start.rules.sh refresh、或自己新增定时器/脚本）
- IPv6：
    - 脚本会尝试在支持 IPv6 的设备上创建等效的 ip6tables 规则若发现设备不支持 IPv6 tproxy，请不要启用 IPv6 对应规则
- 自动更新策略：
    - 默认启用 ENABLE_AUTO_UPDATE=1，会在启动时尝试使用 update-singbox.sh 下载最新 release（若 binary
      缺失或你想自动更新）
    - update-singbox.sh 支持在模块目录放置 github_token 来提供 token
    - 强烈建议你在生产环境中使用固定 release tag 或在 update 脚本中加入签名/sha 校验
