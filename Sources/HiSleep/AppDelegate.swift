import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let monitor = ClamshellMonitor()
    private let enabledKey = "HiSleepEnabled"
    private let lastSleepKey = "HiSleepLastForcedSleep"
    private let lastSleepCountKey = "HiSleepLastForcedSleepBlockers"

    private let lastSleepFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    /// 两次强制睡之间的最小间隔。既防唤醒后一直醒着,也防 sleep→wake→sleep 高频抖动。
    private let minSleepInterval: TimeInterval = 20
    private var lastForcedAt: Date?

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

        updateIcon()
        Log.write("已启动,合盖强制睡眠 = \(enabled)")
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

        // 冷却:距上次强制睡不足 minSleepInterval 则跳过(防抖,也防唤醒后反复睡)
        if let last = lastForcedAt {
            let gap = Date().timeIntervalSince(last)
            if gap < minSleepInterval {
                Log.write("合盖但冷却中(距上次 \(Int(gap))s < \(Int(minSleepInterval))s),跳过")
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

        lastForcedAt = Date()
        UserDefaults.standard.set(Date(), forKey: lastSleepKey)
        UserDefaults.standard.set(raw.count, forKey: lastSleepCountKey)
        // 同步写,确保证据在机器睡着前已落盘
        Log.writeSync("守卫通过 → pmset sleepnow。拦睡 \(raw.count): \(summary)")

        // 强制睡放后台线程,绝不阻塞主线程的菜单/合盖状态机
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = PowerInfo.forceSleep()
            Log.write(ok ? "pmset 睡眠请求已发出(退出码 0)" : "pmset 失败,未睡成")
        }
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
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "HiSleep")
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

        let header = NSMenuItem(title: "HiSleep — 合盖即睡", action: nil, keyEquivalent: "")
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

        let quit = NSMenuItem(title: "退出 HiSleep", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() { enabled.toggle() }

    @objc private func sleepNowAction() {
        lastForcedAt = Date()
        Log.writeSync("手动「立即睡眠」")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = PowerInfo.forceSleep()
            Log.write(ok ? "手动睡眠请求已发出" : "手动睡眠失败")
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
