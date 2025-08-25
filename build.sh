#!/usr/bin/env bash
# build.sh - 在本地把模块目录打包为 Magisk 模块 zip（增强版）
# 用法：
#   把本脚本放到模块根目录（包含 module.prop、service.sh、start.rules.sh、update-singbox.sh、config.json、install.sh、uninstall.sh 等文件）
#   运行 ./build.sh
# 输出：
#   transparent-singbox.zip（位于脚本运行目录）
#
# 功能增强：
# - 确保常用安装/卸载脚本存在并赋可执行权限（install.sh/uninstall.sh）
# - 检查并提醒哪些用户数据建议放到持久目录（/data/adb/transparent-singbox）
# - 打包时尽量保留 unix 权限（zip -X）
#
set -euo pipefail

MODULE_ID="transparent-singbox"
OUTNAME="${MODULE_ID}.zip"
OUTPATH="$(pwd)/${OUTNAME}"
REQUIRED_SCRIPTS=(service.sh update-singbox.sh start.rules.sh install.sh uninstall.sh)

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# 检查 module.prop
if [ ! -f module.prop ]; then
  die "module.prop 未找到，请在模块根目录运行此脚本"
fi

# 确保必要脚本存在（install/uninstall 可选但建议包含）
for f in "${REQUIRED_SCRIPTS[@]}"; do
  if [ ! -f "$f" ]; then
    echo "警告：缺少建议的脚本 '$f'（建议包含以支持安装/卸载/更新流程）"
  fi
done

# 给关键脚本添加可执行权限（以便 zip 中保存）
for f in service.sh update-singbox.sh start.rules.sh install.sh uninstall.sh; do
  if [ -f "$f" ]; then
    chmod 755 "$f" || true
  fi
done

# 清理旧包
if [ -f "$OUTPATH" ]; then
  echo "移除旧打包文件 $OUTPATH"
  rm -f "$OUTPATH"
fi

# 打包（尽量保留权限）
if command -v zip >/dev/null 2>&1; then
  echo "使用 zip 打包到 $OUTPATH"
  # -r 递归，-X 不保存额外属性（保留 unix 权限），排除常见临时文件
  zip -r -X "$OUTPATH" . -x ".*" -x "__MACOSX" -x "*.zip" >/dev/null
elif command -v 7z >/dev/null 2>&1; then
  echo "zip 未安装，使用 7z 打包到 $OUTPATH"
  7z a -tzip "$OUTPATH" * >/dev/null
else
  die "未找到 zip 或 7z，无法打包，请安装 zip 或 p7zip"
fi

if [ -f "$OUTPATH" ]; then
  echo "打包完成： $OUTPATH"
  ls -lh "$OUTPATH"
else
  die "打包失败"
fi

cat <<'EOF'

提示与建议（请阅读）：

1) 持久化目录（推荐）
   - 建议模块运行时产生的用户个性化设置、token、以及较大或需要在模块更新后保留的数据放到设备上的持久目录，例如：
       /data/adb/transparent-singbox/
     或者你也可以使用：
       /data/adb/transparent-singbox/data/
   - 只要不是放在 /data/adb/modules/<module>/ 下（模块目录在更新时会被替换），上述目录通常不会被 Magisk 卸载/更新所删除，能够保留用户配置与日志。
   - 建议放置项：
     - config.json（用户编辑后的配置，或把 module 自带的 config.json 在第一次运行时拷贝到持久目录并从持久目录读取）
     - github_token（用于自动更新）
     - start.rules.sh（若用户改写过自定义规则，可放在持久目录并让 service.sh 优先读取）
     - user settings / profiles / 导入的 rule_set 本地副本
     - logs（可选，建议把日志写到持久目录以便调试）
   - 不建议持久化（不应保留）：
     - pid 文件（runtime 进程信息，重启后会无效）
     - 临时缓存（可选保留，但需管理）
     - 被模块安装器管理的二进制（放在模块目录以便更新）

2) 如何在模块运行时使用持久目录（实现建议）
   - 在模块的 service.sh 或 install.sh 中，检测并创建持久目录，例如：
       PERSIST_DIR=/data/adb/transparent-singbox
       mkdir -p "$PERSIST_DIR"
   - 在第一次运行时（install.sh 或 service.sh 首次启动）：
     - 如果 /data/adb/transparent-singbox/config.json 不存在，则把模块内的默认 config.json 拷贝到该位置；
     - 然后让 service.sh 使用 PERSIST_DIR/config.json（优先）而不是模块内的 config.json。
   - 这样用户编辑 PERSIST_DIR/config.json 后，更新模块 zip 时不会覆盖其配置。

3) 是否必须这样做？
   - 不强制，但强烈建议：如果你希望用户的个性化配置（例如 token、自定义规则、config.json 编辑）在模块更新时保留，则应把这些文件放到持久目录并修改 service.sh/install.sh 来优先读取持久目录的文件。
   - 如果你不需要保存任何个性化设置，则不需要这样做。

4) 我可以帮你做的事情（可选）
   - 我可以把 service.sh 与 install.sh 修改为在首次安装时自动迁移默认配置到 /data/adb/transparent-singbox 并优先使用它；
   - 我也可以把 start.rules.sh 的优先路径改为先查找持久目录中的 start.rules.sh（允许用户自定义规则并在更新后保留）。
   - 如果你需要我现在把这些迁移逻辑加入到 install.sh/service.sh，我可以实现并发给你修改版。

EOF

exit 0