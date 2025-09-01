#!/system/bin/sh
#
# ==============================================================================
# customize.sh - 安装程序调用的脚本
# ==============================================================================
#
# ## 特性:
# - 优雅地停止任何正在运行的旧版本模块实例, 防止新旧文件冲突
# - 使用持久化目录存放用户配置、日志等, 避免模块更新导致配置丢失
# - 支持通过在 /sdcard 目录下放置标记文件来进行预设
# - 初始化模块所需的目录和基础配置文件
#
# ==============================================================================

# 在安装环境中, MODPATH 指向的是模块压缩包解压后的临时目录, 因此明确定义 MODDIR 为模块最终的安装位置
MODDIR=${MODDIR:-/data/adb/modules/$MODID} # 模块最终的安装路径

# 引入公共函数库
# 注意：此时 common.sh 位于 $MODPATH 下, 但其内部逻辑应能适应此上下文
. "$MODPATH/common.sh"

ui_print_safe "[customize.sh]: 开始执行..."
ui_print_safe "本模块最终路径: $MODDIR"
ui_print_safe "本模块临时路径: $MODPATH"
ui_print_safe "持久化数据路径: $PERSIST_DIR"

# ---
# 步骤 1: 尽力优雅地停止现有的模块实例
# ---
# 覆盖文件之前, 确保旧的进程和服务已经完全停止，使用 "best-effort" (尽力而为) 的方式, 因为无法保证所有情况下都能完美停止
if [ -d "$MODDIR" ]; then
  ui_print_safe "模块升级中: 尝试停止旧服务..."

  # 停止服务脚本
  if [ -x "$SERVICE" ]; then
    ui_print_safe "正在停止 $(basename "$SERVICE")..."
    sh "$SERVICE" stop >/dev/null 2>&1 || ui_print_safe "- 脚本调用失败, 可能存在服务未停止"
  fi

  # 通过进程名进行全面清理
  if command -v readlink >/dev/null 2>&1; then
    ui_print_safe "正在查找并终止残留进程..."
    for pid in $(ps -A | awk -v modid="$MODID" -v bin="$BIN_NAME" '$0 ~ bin && $0 ~ modid && !/awk/ {print $1}'); do
      exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo "unknown")
      ui_print_safe "- 发现残留进程 $pid $exe, 正在终止"
      kill -9 "$pid" >/dev/null 2>&1
    done
  fi

  # 备份旧的日志文件
  if [ -f "$LOGFILE" ]; then
    ui_print_safe "正在备份旧的日志文件..."
    # 使用 mv -f 强制覆盖已存在的备份, 确保只保留上一次的日志
    mv -f "$LOGFILE" "$LOGFILE.bak" 2>/dev/null
  fi

  sleep 1
else
  ui_print_safe "正在安装模块..."
fi

# ---
# 步骤 2: 确保持久化数据目录存在
# ---
# 此目录用于存放用户配置、数据库等不应随模块更新而丢失的文件
if [ ! -d "$PERSIST_DIR" ]; then
  ui_print_safe "创建持久化目录: $PERSIST_DIR"
  mkdir -p "$PERSIST_DIR"
  # 设置正确的权限和 SELinux 上下文, 确保模块运行时有权访问
  set_perm_safe 0 0 0755 "$PERSIST_DIR"
fi

# ---
# 步骤 3: 从模块包迁移通用用户文件
# ---
# 首次安装时, 此步骤会将其移动到持久化目录
for f in config.json settings.conf github_token; do
  if [ -f "$MODPATH/$f" ] && [ ! -f "$PERSIST_DIR/$f" ]; then
    ui_print_safe "正在迁移文件 '$f'..."
    mv "$MODPATH/$f" "$PERSIST_DIR/"
    set_perm_safe 0 0 0600 "$PERSIST_DIR/$f"
  fi
done

# ---
# 步骤 4: 设置文件权限
# ---
# 使用 set_perm* 命令来设置最终安装后的文件和目录的权限与 SELinux 上下文
ui_print_safe "正在设置文件权限..."

# 目录: 755 (rwxr-xr-x) - 所有者可读写执行, 组和其他用户可读可执行
# 文件: 644 (rw-r--r--) - 所有者可读写, 组和其他用户只读
set_perm_recursive_safe "$MODPATH" 0 0 0755 0644
ui_print_safe "- 已赋予所有文件默认权限"

# 为所有需要执行的脚本和二进制文件单独设置可执行权限 (755)
if [ -f "$MODPATH/$BIN_NAME" ]; then
  set_perm_safe "$MODPATH/$BIN_NAME" 0 0 0755
  ui_print_safe "- 已赋予代理核心可执行权限"
fi

# 使用循环为所有 .sh 脚本设置可执行权限, 避免遗漏
for script in "$MODPATH"/*.sh; do
  if [ -f "$script" ]; then
    set_perm_safe "$script" 0 0 0755
    ui_print_safe "- 已赋予 $(basename "$script") 可执行权限"
  fi
done

ui_print_safe "[customize.sh]: 执行完毕"
exit 0