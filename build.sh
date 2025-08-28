#!/usr/bin/env bash
# build.sh - 把模块目录打包为 Magisk 模块 zip（增强版）
set -euo pipefail

# 从 module.prop 动态获取模块 ID
if ! MODULE_ID=$(grep '^id=' module.prop | cut -d= -f2); then
  die "无法从 module.prop 读取 id"
fi
[ -z "$MODULE_ID" ] && die "从 module.prop 读取的 id 为空"

OUTNAME="${MODULE_ID}.zip"
OUTPATH="$(pwd)/${OUTNAME}"
REQUIRED_SCRIPTS=(common.sh customize.sh service.sh start.rules.sh update-singbox.sh)
EXCLUDES=(".git/*" ".idea/*" "build.sh" "*.zip" "__MACOSX" ".DS_Store")

die() { echo "ERROR: $*" >&2; exit 1; }

if [ ! -f module.prop ]; then die "module.prop 未找到，请在模块根目录运行此脚本"; fi

# 检查并设置所需脚本的权限
for f in "${REQUIRED_SCRIPTS[@]}"; do
  if [ ! -f "$f" ]; then
    echo "警告：缺少建议的脚本 '$f'"
  else
    chmod 755 "$f"
  fi
done

# 清理旧的 zip 文件
if [ -f "$OUTPATH" ]; then rm -f "$OUTPATH"; fi

# 构建排除列表参数
ZIP_EXCLUDES=()
for ex in "${EXCLUDES[@]}"; do
  ZIP_EXCLUDES+=("-x" "$ex")
done

# 使用 zip 或 7z 打包
if command -v zip >/dev/null 2>&1; then
  echo "使用 zip 打包到 $OUTPATH"
  zip -r -X "$OUTPATH" . "${ZIP_EXCLUDES[@]}" >/dev/null
elif command -v 7z >/dev/null 2>&1; then
  echo "使用 7z 打包到 $OUTPATH"
  SEVENZIP_EXCLUDES=()
  for ex in "${EXCLUDES[@]}"; do
    SEVENZIP_EXCLUDES+=("-x!$ex")
  done
  7z a -tzip "$OUTPATH" . "${SEVENZIP_EXCLUDES[@]}" >/dev/null
else
  die "未找到 zip 或 7z，无法打包，请安装 zip 或 p7zip"
fi

if [ -f "$OUTPATH" ]; then
  echo "打包完成： $OUTPATH"
  ls -lh "$OUTPATH"
else
  die "打包失败"
fi

exit 0