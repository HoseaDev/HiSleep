#!/usr/bin/env bash
# ShutEye 安装脚本(对方运行)。装 app + 配 sudoers 免密 + 可选开机自启。
# 用法:解压分发包后,在终端 cd 进该目录,执行  ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ShutEye"
APP="${APP_NAME}.app"
DEST="/Applications/${APP}"

[ -d "$APP" ] || { echo "找不到 ${APP}(请把本脚本和 ${APP} 放在同一目录)" >&2; exit 1; }

echo "==> 安装到 /Applications(需要管理员密码)"
sudo rm -rf "$DEST"
sudo cp -R "$APP" "$DEST"

echo "==> 去掉「下载隔离」属性(否则 Gatekeeper 会拦)"
sudo xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> 配置 sudoers 免密:让 ShutEye 能复位系统 disablesleep 开关"
echo "    (只允许免密执行 pmset -a disablesleep 0 这一条命令,不开其它权限)"
SUDOERS="/etc/sudoers.d/shuteye"
echo '%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0' | sudo tee "$SUDOERS" >/dev/null
sudo chmod 440 "$SUDOERS"
if sudo visudo -cf "$SUDOERS" >/dev/null 2>&1; then
    echo "    sudoers 校验通过 ✅"
else
    echo "    sudoers 校验失败,已撤销该规则(disablesleep 复位将不可用)" >&2
    sudo rm -f "$SUDOERS"
fi

read -r -p "==> 设为开机自启?[y/N] " yn
if [[ "${yn:-}" =~ ^[Yy]$ ]]; then
    PLIST="$HOME/Library/LaunchAgents/com.hosea.shuteye.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.hosea.shuteye</string>
    <key>ProgramArguments</key>
    <array><string>${DEST}/Contents/MacOS/${APP_NAME}</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
PL
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    echo "    已设开机自启并启动 ✅"
else
    open "$DEST"
    echo "    已启动(未设开机自启)✅"
fi

echo
echo "完成。菜单栏右上会出现月亮图标。合盖即睡。"
echo "日志在 ~/Library/Logs/${APP_NAME}.log"
