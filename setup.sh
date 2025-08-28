#!/system/bin/sh
#
# ==============================================================================
# setup.sh - 交互式安装后配置向导
# ==============================================================================
#
# ## 功能：
# - 配置模块的运行时选项（如监控和自动刷新）
# - 将配置保存到持久化目录
# - 根据需要重启服务以应用新配置
#
# ==============================================================================

# 当任何命令返回非零退出码时立即退出
set -e

# --- 初始化与变量定义 ---
MODDIR=${0%/*}
. "$MODDIR/common.sh"

# 读取用户选择
# 参数1: 提示信息
# 参数2: 默认选项 (1=是, 2=否)
read_choice() {
  prompt="$1"; default="$2"
  echo
  echo "$prompt"
  echo "  1) 是"
  echo "  2) 否"
  printf "请选择 [1/2] (默认 %s): " "$default"
  read -r opt
  # 如果用户直接回车, 则使用默认值
  if [ -z "$opt" ]; then opt="$default"; fi
  case "$opt" in 1) return 0 ;; 2) return 1 ;; *) return 1 ;; esac
}

# --- 脚本主逻辑 ---
echo "欢迎使用 $MODID 模块配置向导"
echo "配置文件将保存到: $SETTING"

if read_choice "是否启用服务守护进程 (崩溃后自动重启 sing-box)?" 1; then
  write_setting "ENABLE_MONITOR" "1"
  echo "守护进程已启用"
else
  write_setting "ENABLE_MONITOR" "0"
  echo "守护进程已禁用"
fi

if read_choice "是否启用代理核心自动更新?" 2; then
  write_setting "ENABLE_AUTO_UPDATE" "1"
  echo "自动更新已启用"
else
  write_setting "ENABLE_AUTO_UPDATE" "0"
  echo "自动更新已禁用"
fi

if read_choice "是否启用 IPSet 规则定期刷新?" 2; then
  write_setting "ENABLE_REFRESH" "1"
  echo "定期刷新已启用"
else
  write_setting "ENABLE_REFRESH" "0"
  echo "定期刷新已禁用"
fi

echo
printf "是否立即重启模块以应用更改? [y/N]: "
read -r go
# 使用 grep -i 进行不区分大小写的匹配
if echo "$go" | grep -qiE '^(y|yes)$'; then
  if [ -x "$SERVICE" ]; then
    # 先停止服务, 再启动, 确保配置完全重新加载
    sh "$SERVICE" >/dev/null 2>&1 || true
    echo "服务已重启"
  else
    echo "错误：服务脚本不存在或不可执行: $SERVICE"
  fi
fi

echo "配置完成, 如果需要, 您可以随时手动编辑 $SETTING 文件"