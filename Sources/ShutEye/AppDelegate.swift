import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let monitor = ClamshellMonitor()
    private let enabledKey = "ShutEyeEnabled"
    private let lastSleepKey = "ShutEyeLastForcedSleep"
    private let lastSleepCountKey = "ShutEyeLastForcedSleepBlockers"

    private let lastSleepFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    /// 两次强制睡之间的最小间隔。既防唤醒后一直醒着,也防 sleep→wake→sleep 高频抖动。
    private let minSleepInterval: TimeInterval = 20
    private var lastForcedAt: Date?

    /// 睡眠失败(如 SleepDisabled 没复位、pmset 被拒)后的退避窗口。这类失败往往是持久的,
    /// 合盖期间通知可能反复触发,没有退避就会反复砸 pmset、刷屏日志。
    private let failBackoff: TimeInterval = 10
    private var lastFailedAt: Date?

    /// 合盖轮询:每隔 pollInterval 秒主动看一次盖子状态。比单纯依赖 IOPM 事件通知更可靠
    /// (某些机器通知不触发)。合着就尝试睡,冷却/退避负责防抖。
    private let pollInterval: TimeInterval = 3
    private var pollTimer: Timer?
    /// 上一次轮询时盖子是否合着,用于只在状态变化时记一条日志(避免每 3s 刷屏)。
    private var pollLastClosed = false

    /// 解析后的拦睡者:带真实 App 名和图标(代持场景已穿透到真凶)。
    private struct DisplayBlocker {
        let name: String
        let detail: String
        let icon: NSImage?
    }

    private var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            updateIcon()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        monitor.onShouldSleep = { [weak self] in self?.handleShouldSleep() }
        monitor.start()

        // 主动轮询合盖状态,绕开 IOPM 事件通知可能不触发的问题
        let timer = Timer.scheduledTimer(timeInterval: pollInterval, target: self,
                                         selector: #selector(pollClamshell),
                                         userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        updateIcon()
        Log.write("已启动,合盖强制睡眠 = \(enabled),每 \(Int(pollInterval))s 轮询合盖")
    }

    /// 定时轮询:盖子合着就交给统一的睡眠逻辑(handleShouldSleep 内含守卫+冷却+退避)。
    /// 盖子开着时安静跳过;合↔开状态变化时各记一条日志,方便你从日志看出它在工作。
    @objc private func pollClamshell() {
        guard enabled else { return }
        let closed = PowerInfo.clamshellClosed()
        if closed != pollLastClosed {
            Log.write(closed ? "轮询:检测到合盖" : "轮询:检测到开盖")
            pollLastClosed = closed
        }
        guard closed else { return }
        handleShouldSleep()
    }

    // MARK: - 拦睡者解析(穿透代持 → 真实 App 名 + 图标)

    private func resolveBlockers() -> [DisplayBlocker] {
        PowerInfo.rawBlockers().map { raw in
            var name: String
            var icon: NSImage?
            if let app = NSRunningApplication(processIdentifier: raw.culpritPID) {
                // GUI App:真实本地化名 + 真实图标
                name = app.localizedName
                    ?? app.bundleIdentifier
                    ?? PowerInfo.processName(for: raw.culpritPID)
                    ?? "pid \(raw.culpritPID)"
                icon = app.icon
            } else {
                // daemon/无 GUI 进程:用进程名 + 可执行文件的通用图标(不会为空)
                name = PowerInfo.processName(for: raw.culpritPID) ?? raw.ownerName
                if let path = PowerInfo.processPath(for: raw.culpritPID) {
                    icon = NSWorkspace.shared.icon(forFile: path)
                }
            }
            let via = raw.isProxied ? "经 \(raw.ownerName)·" : ""
            return DisplayBlocker(name: name, detail: via + PowerInfo.shortType(raw.type), icon: icon)
        }
    }

    // MARK: - 核心动作

    private func handleShouldSleep() {
        guard enabled else { Log.write("合盖但功能已关闭,不动作"); return }

        // 冷却:距上次成功强制睡不足 minSleepInterval 则跳过(防抖,也防唤醒后反复睡)
        if let last = lastForcedAt {
            let gap = Date().timeIntervalSince(last)
            if gap < minSleepInterval {
                Log.write("合盖但冷却中(距上次 \(Int(gap))s < \(Int(minSleepInterval))s),跳过")
                return
            }
        }
        // 失败退避:上次睡眠失败后短时间内不重试,避免持久失败(如 SleepDisabled 没复位)反复砸 pmset
        if let failed = lastFailedAt {
            let gap = Date().timeIntervalSince(failed)
            if gap < failBackoff {
                Log.write("合盖但上次睡眠失败,退避中(\(Int(gap))s < \(Int(failBackoff))s),跳过")
                return
            }
        }

        guard PowerInfo.shouldForceSleep() else {
            Log.writeSync("合盖但守卫未通过(外接屏+电源 或 系统判定不睡),跳过")
            return
        }

        // 轻量取拦睡者名字(只用进程名,不取图标/不查 LaunchServices,避免拖慢睡眠路径)
        let raw = PowerInfo.rawBlockers()
        let summary = raw.map { PowerInfo.processName(for: $0.culpritPID) ?? $0.ownerName }
            .joined(separator: ", ")

        // 同步写,确保证据在机器睡着前已落盘
        Log.writeSync("守卫通过 → 准备强制睡眠。拦睡 \(raw.count): \(summary)")

        // 实际睡眠放后台线程,绝不阻塞主线程的菜单/合盖状态机
        let blockerCount = raw.count
        DispatchQueue.global(qos: .userInitiated).async {
            self.performForceSleep(blockerCount: blockerCount)
        }
    }

    /// 后台线程执行的强制睡眠,自动合盖与手动「立即睡眠」共用。
    /// 先处理 SleepDisabled:这是系统级持久设置(常被 ToDesk 等远程软件用 `pmset -a disablesleep 1`
    /// 设上),开着时连 root 的 `pmset sleepnow` 都会被拒,且杀进程清不掉它,必须用特权命令复位。
    private func performForceSleep(blockerCount: Int) {
        if PowerInfo.sleepDisabled() {
            if PowerInfo.resetDisableSleep() {
                Log.write("检测到 SleepDisabled=1,已复位 disablesleep=0")
            } else {
                Log.write("SleepDisabled=1 且复位失败:需为 pmset -a disablesleep 0 配 sudoers 免密,否则无法强制睡")
                DispatchQueue.main.async { self.lastFailedAt = Date() }
                return
            }
        }

        let ok = PowerInfo.forceSleep()
        DispatchQueue.main.async {
            if ok {
                // 只有真发出睡眠请求才记冷却 + 证据,并清掉失败退避
                self.lastForcedAt = Date()
                self.lastFailedAt = nil
                UserDefaults.standard.set(Date(), forKey: self.lastSleepKey)
                UserDefaults.standard.set(blockerCount, forKey: self.lastSleepCountKey)
            } else {
                self.lastFailedAt = Date()
            }
        }
        Log.write(ok
            ? "pmset 睡眠请求已发出(退出码 0)"
            : "pmset 失败,未睡成(退避 \(Int(failBackoff))s 后可重试)")
    }

    // MARK: - 菜单栏图标

    private func updateIcon(blockerCount: Int? = nil) {
        guard let button = statusItem.button else { return }
        let count = blockerCount ?? PowerInfo.rawBlockers().count
        let symbol: String
        if !enabled {
            symbol = "moon.slash"            // 已关闭
        } else if count > 0 {
            symbol = "moon.zzz.fill"         // 有人拦睡
        } else {
            symbol = "moon.fill"             // 正常待命
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "ShutEye")
        img?.isTemplate = true
        button.image = img
    }

    // MARK: - NSMenuDelegate(每次打开重建,显示实时拦睡者)

    func menuWillOpen(_ menu: NSMenu) {
        let blockers = resolveBlockers()   // 每次打开只调一次 IOKit
        rebuildMenu(menu, blockers: blockers)
        updateIcon(blockerCount: blockers.count)
    }

    private func rebuildMenu(_ menu: NSMenu, blockers: [DisplayBlocker]) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "ShutEye — 合盖即睡", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "合盖时强制睡眠",
                                action: #selector(toggleEnabled),
                                keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        // 上次强制睡眠的证据:重开盖点菜单就能看到
        if let last = UserDefaults.standard.object(forKey: lastSleepKey) as? Date {
            let count = UserDefaults.standard.integer(forKey: lastSleepCountKey)
            let item = NSMenuItem(
                title: "上次强制睡眠: \(lastSleepFormatter.string(from: last))(拦睡 \(count))",
                action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "尚未强制睡眠过", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let title = blockers.isEmpty ? "现在没人拦睡 ✅" : "现在拦睡(\(blockers.count)):"
        let blockerHeader = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        blockerHeader.isEnabled = false
        menu.addItem(blockerHeader)
        for b in blockers {
            let item = NSMenuItem(title: "\(b.name) — \(b.detail)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            if let icon = b.icon {
                let small = icon.copy() as! NSImage
                small.size = NSSize(width: 16, height: 16)
                item.image = small
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let sleepNow = NSMenuItem(title: "立即睡眠", action: #selector(sleepNowAction), keyEquivalent: "")
        sleepNow.target = self
        menu.addItem(sleepNow)

        let openLog = NSMenuItem(title: "查看日志", action: #selector(openLogAction), keyEquivalent: "")
        openLog.target = self
        menu.addItem(openLog)

        let quit = NSMenuItem(title: "退出 ShutEye", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() { enabled.toggle() }

    @objc private func sleepNowAction() {
        Log.writeSync("手动「立即睡眠」")
        let blockerCount = PowerInfo.rawBlockers().count
        DispatchQueue.global(qos: .userInitiated).async {
            self.performForceSleep(blockerCount: blockerCount)
        }
    }

    @objc private func openLogAction() {
        if !FileManager.default.fileExists(atPath: Log.fileURL.path) {
            Log.write("日志文件初始化")
        }
        NSWorkspace.shared.open(Log.fileURL)
    }

    @objc private func quitAction() { NSApp.terminate(nil) }
}
