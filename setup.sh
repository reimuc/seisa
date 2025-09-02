#!/system/bin/sh
#
# ============================================================================== 
# ⚙️ setup.sh - 交互式安装后配置向导
# ============================================================================== 
#
# 引导用户完成模块关键运行参数配置，支持服务守护进程启用、端口与透明代理设置等。
# - 交互式引导，简化配置流程
# - 支持守护进程、端口、透明代理等选项
# - 自动检测环境并保存配置
#
# ============================================================================== 
set -e

# --- 初始化与变量定义 ---
MODDIR=$(dirname "$0")
# shellcheck source=common.sh
. "$MODDIR/common.sh"

# --- 辅助函数 ---

# 读取用户选择
# 参数1: 提示信息
# 参数2: 默认选项 (1=是, 2=否)
read_choice() {
  prompt="$1"; default="$2"
  ui_print " "
  ui_print "🤔 $prompt"
  ui_print "    1) 是"
  ui_print "    2) 否"
  ui_print -n "- 请输入您的选择 [1/2] (默认: $default): "
  read -r opt
  # 如果用户直接回车, 则使用默认值
  if [ -z "$opt" ]; then opt="$default"; fi
  case "$opt" in 1) return 0 ;; 2) return 1 ;; *) return 1 ;; esac
}

# --- 脚本主逻辑 ---
ui_print " "
ui_print "======================================================="
ui_print "        🧙‍♂️ 欢迎使用 $MODID 配置向导 🧙‍♂️"
ui_print "======================================================="
ui_print "- 配置文件将保存到: $SETTING"

if read_choice "是否启用服务守护进程 (核心崩溃后自动重启)?" 1; then
  write_setting "ENABLE_MONITOR" "1"
  ui_print "- ✅ 守护进程已启用。"
else
  write_setting "ENABLE_MONITOR" "0"
  ui_print "- ❌ 守护进程已禁用。"
fi

if read_choice "是否启用代理核心自动更新?" 2; then
  write_setting "ENABLE_AUTO_UPDATE" "1"
  ui_print "- ✅ 自动更新已启用。"
else
  write_setting "ENABLE_AUTO_UPDATE" "0"
  ui_print "- ❌ 自动更新已禁用。"
fi

if read_choice "是否启用 IPSet 规则定期刷新 (推荐用于动态 IP)?" 2; then
  write_setting "ENABLE_REFRESH" "1"
  ui_print "- ✅ 定期刷新已启用。"
else
  write_setting "ENABLE_REFRESH" "0"
  ui_print "- ❌ 定期刷新已禁用。"
fi

ui_print " "
ui_print "💡 您希望现在重启模块以应用更改吗?"
ui_print -n "- 请输入您的选择 [y/N]: "
read -r go
# 使用 case 和不区分大小写的匹配
case "$go" in
  [yY] | [yY][eE][sS])
    ui_print "- 🔄 正在重启服务..."
    if [ -x "$SERVICE" ]; then
      # 先停止服务, 再启动, 确保配置完全重新加载
      sh "$MODDIR/action.sh" switch >/dev/null 2>&1 || true
      ui_print "- ✅ 服务已成功重启!"
    else
      ui_print "- ❌ 错误: 服务脚本 $(basename "$SERVICE") 未找到或不可执行。"
    fi
    ;;
  *)
    ui_print "- ℹ️ 您选择了稍后手动重启。"
    ;;
esac

ui_print " "
ui_print "✨ 配置完成! 如果需要, 您可以随时运行此脚本或手动编辑 $SETTING 文件。"
ui_print "======================================================="