```markdown
# Transparent sing-box Magisk 模块（tproxy 优先）

功能
- 以 tproxy 为主实现透明代理（支持 TCP/UDP，包括 QUIC 在内但取决于内核/设备对 UDP TPROXY 的支持）
- 支持 fakeip + hijack-dns，用于在无法通过 sniff 获取域名信息的 UDP/QUIC 场景下实现域名分流
- 自动将 config.json 中 declared "server" 主机解析为 IP 并加入 ipset，以避免 sing-box 与其 outbound 服务器之间形成代理环路
- 支持 IPv6（若设备内核与 ip6tables 支持 IPv6 tproxy）
- 自动更新脚本从 SagerNet/sing-box Releases 下载最新适用于 Android arm64 的包（可选，支持 GitHub token）

重要文件
- module.prop
- service.sh            -> magisk late_start service 脚本
- update-singbox.sh     -> 自动下载/更新 sing-box release（可使用 GitHub token）
- start.rules.sh        -> 完整 iptables/ip6tables + ipset 启动脚本（包含 refresh 子命令）
- config.json           -> 推荐的 sing-box 配置（tproxy 优先、保留 fakeip/dns/route）
- README.md             -> 你正在阅读的文件

配置与使用
1. 解包模块目录到 /data/adb/modules/transparent-singbox （或在本地打包并通过 Magisk 安装）
2. 将你的 sing-box 可执行文件（如果不使用自动更新）放置到模块目录并 chmod +x：
   - /data/adb/modules/transparent-singbox/sing-box
3. （可选）添加 GitHub token：
   - 在模块目录创建文件 github_token，内容为你的 GitHub Personal Access Token（只需要 public repo 读取权限即可）
   - 或在环境里设置 GITHUB_TOKEN / GH_TOKEN
   使用 token 可以避免 API 限制并提高稳定性
4. 根据你的实际 outbound 填写或替换 config.json 中的 outbounds 部分（当前包含占位的 "Direct" 与 "Proxy"）
5. 授权脚本可执行：
   chmod 755 /data/adb/modules/transparent-singbox/service.sh /data/adb/modules/transparent-singbox/update-singbox.sh /data/adb/modules/transparent-singbox/start.rules.sh
6. 启用模块并重启（Magisk late_start 会自动调用 service.sh），或手动启动：
   /data/adb/modules/transparent-singbox/service.sh start
   日志文件：/data/adb/modules/transparent-singbox/transparent-singbox.log
7. 停止：
   /data/adb/modules/transparent-singbox/service.sh stop

注意与建议
- 停用 tun/redirect：当前 config.json 已移除 tun 与 redirect inbounds，仅保留 tproxy inbound。若你希望保留以防万一，可自行恢复并对应调整规则。
- DNS 与 fakeip：
  - 若想让 rule_set（域名分流）在 UDP/QUIC 上也可靠工作，建议使用 hijack-dns + fakeip（当前 config.json 已启用 fakeip 的示例范围）。
  - 模块会尝试把系统 DNS (53) 捕获到 sing-box（通过 TPROXY），并由 sing-box 的 hijack-dns 处理（请验证 sing-box 的 DNS 相关监听/行为，某些场景需要额外的 dns inbound）。
- 避免回路（必须）：
  - 模块会解析 config.json 中的 outbound server 主机名并把解析到的 IP 写入 ipset（或直接放入 iptables），以确保 sing-box 到其远端节点的连接不会被再次重定向回 sing-box。
  - 由于远端服务器 IP 可能变化（CDN），建议启用定期刷新（可通过触发 start.rules.sh refresh、或自己新增定时器/脚本）。
- IPv6：
  - 脚本会尝试在支持 IPv6 的设备上创建等效的 ip6tables 规则。若发现设备不支持 IPv6 tproxy，请不要启用 IPv6 对应规则。
- 自动更新策略：
  - service.sh 默认启用 ENABLE_AUTO_UPDATE=1，会在启动时尝试使用 update-singbox.sh 下载最新 release（若 binary 缺失或你想自动更新）。
  - update-singbox.sh 支持在模块目录放置 github_token 来提供 token。
  - 强烈建议你在生产环境中使用固定 release tag 或在 update 脚本中加入签名/sha 校验（当前脚本出于通用性并未做签名校验）。

打包为 Magisk 模块 zip（本地）
1. 在模块目录（包含 module.prop 与其它文件）执行：
   zip -r transparent-singbox.zip * 
   （确保 module.prop 在 zip 根目录）
2. 将生成的 zip 放入手机并通过 Magisk 安装，或直接把模块文件夹放到 /data/adb/modules/ 并重启。

如果你希望我：
- 1) 把 update-singbox.sh 改为只在 binary 缺失时才下载（当前为尝试下载但不会强制覆盖），
- 2) 或者将更新修改为每天检查一次并写入一个日志/版本号文件，
请告诉我你的偏好，我会修改脚本并给出 final 包。

```