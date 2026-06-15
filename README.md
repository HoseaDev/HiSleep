# ShutEye

让 MacBook「该睡就睡」。合盖时无视流氓 App 的 power assertion,强制摁进睡眠。

设计文档见 [`DESIGN.md`](./DESIGN.md)。

## 它做什么

- 常驻菜单栏(月亮图标,无 Dock 图标)。
- 监听合盖事件;盖子合上且通过守卫判断时,执行 `pmset sleepnow` 强制睡眠。
- 菜单里能看到「现在谁在拦睡」(best-effort),并能一键「立即睡眠」/ 开关功能。

**守卫(关键):** 接外接显示器、或系统判定 `AppleClamshellCausesSleep == false` 时
**不会**强制睡,避免毁掉外接屏工作流。

## 构建 & 运行

```bash
swift build -c release
.build/release/ShutEye
```

或开发期直接:

```bash
swift run
```

菜单栏右上会出现月亮图标。点开可以开关、查看拦睡者、立即睡眠、退出。

## 怎么确认它真的睡了(而不是像以前那样没睡)

三个由近到「铁证」的办法:

1. **菜单里看**:重新开盖,点菜单栏图标 → 顶部有「上次强制睡眠: MM-dd HH:mm:ss(拦睡 N)」。
   有这行、时间对得上你合盖的时刻 = 它动手了。

2. **App 日志**:菜单点「查看日志」,或直接看 `~/Library/Logs/ShutEye.log`。会有完整链路:
   ```
   ... 检测到合盖(上升沿)
   ... 守卫通过 → 执行 pmset sleepnow。当时拦睡 4: ToDesk — UserIdleSystemSleep, ...
   ... pmset 睡眠请求已发出(退出码 0)
   ```
   如果看到的是「守卫未通过…跳过」,说明它**故意**没睡(比如接了外接屏 + 电源)。

3. **系统铁证 `pmset -g log`**(这个骗不了人,记录真实的睡/醒):
   ```bash
   pmset -g log | grep -iE "Sleep|Wake" | tail -20
   ```
   找你合盖那一刻附近的 `Sleep` 事件,以及开盖时的 `Wake`。两者之间有时间差 = 真睡了。
   反之,如果合盖期间机身发烫、风扇转、`pmset -g log` 里没有对应 Sleep,就是没睡成。

> 对比验证:合盖前看一眼日志行数,合盖几分钟后开盖再看,多出 sleepnow 那几行就对了。

最简单的方式,建一个 LaunchAgent:

1. 先 `swift build -c release`,记下二进制绝对路径:
   `/Volumes/HoseaExtension/CodeWork/Project/ShutEye/.build/release/ShutEye`
2. 新建 `~/Library/LaunchAgents/com.hosea.shuteye.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.hosea.shuteye</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Volumes/HoseaExtension/CodeWork/Project/ShutEye/.build/release/ShutEye</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

3. 加载:`launchctl load ~/Library/LaunchAgents/com.hosea.shuteye.plist`

> 注:二进制放在外接卷(`/Volumes/...`)上,卷没挂载时自启会失败。
> 若要稳妥,把 release 二进制拷到 `~/Applications/` 或本机磁盘再指过去。

## v1 已知边界(见 DESIGN.md)

- 合盖检测靠 IOPMrootDomain 的 interest 通知重读 `AppleClamshellState`,
  未用 `kIOPMMessageClamshellStateChange` 常量(Swift 未稳定导出)。
- 「真实代持 App」(coreaudiod 背后的子 PID)无稳定 API,菜单里只显示 owning process。
- `pmset sleepnow` 能绕 idle 声明,但不保证绕过 `PreventSystemSleep`(本机目前没有)。
