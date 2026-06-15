import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import CoreGraphics

/// 读取 macOS 电源/合盖状态,并提供强制睡眠。全部走公开 API,不需要 root。
enum PowerInfo {

    /// 读 IOPMrootDomain 的一个布尔属性。返回 nil 表示该机型不暴露此属性。
    private static func rootDomainBool(_ key: String) -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault,
                                               IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        guard let prop = IORegistryEntryCreateCFProperty(root, key as CFString,
                                                         kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        return (prop as? NSNumber)?.boolValue
    }

    /// 盖子是否合上。属性缺失(台式机/异常)时按「未合盖」处理并记一条日志。
    static func clamshellClosed() -> Bool {
        guard let closed = rootDomainBool("AppleClamshellState") else {
            return false
        }
        return closed
    }

    /// 这次合盖系统是否「应该」睡。clamshell 桌面模式下为 false。机型不暴露则 nil。
    static func clamshellCausesSleep() -> Bool? {
        rootDomainBool("AppleClamshellCausesSleep")
    }

    /// 是否接了外接显示器。
    static func hasExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return false
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            return false
        }
        for id in ids where CGDisplayIsBuiltin(id) == 0 && CGDisplayIsActive(id) != 0 {
            return true
        }
        return false
    }

    /// 当前是否接电源(AC)。clamshell 桌面模式必然接电源;电池供电下合盖本就该睡。
    static func onACPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPSACPowerValue
    }

    /// 合盖后是否应该强制睡。守卫(任一不通过就不睡):
    /// 1. 系统明确判定 `AppleClamshellCausesSleep == false` → 不睡。
    /// 2. 接外接显示器 **且** 接电源 → 视为 clamshell 桌面,不睡。
    /// 电池供电下即使接屏也睡(系统本就会睡),属性缺失则按普通笔记本合盖处理。
    static func shouldForceSleep() -> Bool {
        guard clamshellClosed() else { return false }
        if let causes = clamshellCausesSleep(), causes == false { return false }
        if hasExternalDisplay() && onACPower() { return false }
        return true
    }

    /// 一条「拦睡」声明的原始信息(不含 AppKit,图标/显示名在 AppDelegate 里解析)。
    struct RawBlocker {
        let type: String          // PreventUserIdleSystemSleep / PreventSystemSleep
        let ownerPID: pid_t       // 直接持有者(可能是 coreaudiod 这种代持者)
        let ownerName: String     // 持有者进程名
        let onBehalfPID: pid_t?   // 真凶 PID(代持场景,来自 AssertionOnBehalfOfPID)
        /// 取图标/真实名应该用的 PID:优先真凶,否则持有者。
        var culpritPID: pid_t { onBehalfPID ?? ownerPID }
        var isProxied: Bool { onBehalfPID != nil && onBehalfPID != ownerPID }
    }

    /// 当前所有「拦睡」声明。字段经真机 dump 确认:
    /// AssertType / AssertPID / Process Name / AssertionOnBehalfOfPID / AssertLevel。
    static func rawBlockers() -> [RawBlocker] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byPID = unmanaged?.takeRetainedValue() as? [AnyHashable: Any]
        else { return [] }

        let blockingTypes: Set<String> = [
            kIOPMAssertionTypePreventUserIdleSystemSleep as String,
            kIOPMAssertionTypePreventSystemSleep as String
        ]

        var result: [RawBlocker] = []
        var seen = Set<String>()
        for (_, value) in byPID {
            guard let assertions = value as? [[String: Any]] else { continue }
            for a in assertions {
                let type = (a["AssertType"] as? String)
                    ?? (a[kIOPMAssertionTypeKey as String] as? String)
                guard let type = type, blockingTypes.contains(type) else { continue }
                if let level = a["AssertLevel"] as? NSNumber, level.intValue == 0 { continue }

                let ownerPID = (a["AssertPID"] as? NSNumber)?.int32Value ?? -1
                let ownerName = (a["Process Name"] as? String)
                    ?? processName(for: ownerPID) ?? "pid \(ownerPID)"
                // 校验代持 PID:必须 > 0 且不等于持有者本身,否则忽略(防 0/负数/脏值)
                let rawOnBehalf = (a["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value
                let onBehalf: pid_t? = (rawOnBehalf != nil && rawOnBehalf! > 0 && rawOnBehalf! != ownerPID)
                    ? rawOnBehalf : nil

                let blocker = RawBlocker(type: type, ownerPID: ownerPID,
                                         ownerName: ownerName, onBehalfPID: onBehalf)
                // 按 真凶PID+类型 去重
                let dedupKey = "\(blocker.culpritPID)|\(type)"
                if seen.insert(dedupKey).inserted { result.append(blocker) }
            }
        }
        return result
    }

    static func shortType(_ type: String) -> String {
        type.replacingOccurrences(of: "Prevent", with: "")
    }

    static func processPath(for pid: pid_t) -> String? {
        guard pid >= 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    static func processName(for pid: pid_t) -> String? {
        guard let path = processPath(for: pid) else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// 跑一个外部命令,返回 (退出码, stdout+stderr 合并后的文本)。退出码 -1 表示无法启动。
    private static func runProcess(_ path: String, _ args: [String]) -> (code: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            // 先读尽输出再 wait,避免管道写满死锁
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (task.terminationStatus, text)
        } catch {
            NSLog("ShutEye: 执行 \(path) \(args.joined(separator: " ")) 失败: \(error)")
            return (-1, error.localizedDescription)
        }
    }

    /// 系统是否被设了全局 disablesleep(`pmset -g` 里的 SleepDisabled 行为 1)。
    /// 开着时连 root 的 `pmset sleepnow` 都会被拒(kIOReturnNotPermitted / 0xe00002e2)。
    /// 读不到则按 false 处理。
    static func sleepDisabled() -> Bool {
        let (_, out) = runProcess("/usr/bin/pmset", ["-g"])
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            let value = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last
            return String(value ?? "") == "1"
        }
        return false
    }

    /// 复位全局 disablesleep 为 0。需要 root,走 `sudo -n`(非交互、绝不弹密码):
    /// 必须先配 sudoers 免密规则 `NOPASSWD: /usr/bin/pmset -a disablesleep 0`,否则直接失败。
    /// 返回 true 表示已复位。
    @discardableResult
    static func resetDisableSleep() -> Bool {
        let (code, out) = runProcess("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
        if code != 0 {
            NSLog("ShutEye: 复位 disablesleep 失败(退出码 \(code)): \(out)")
        }
        return code == 0
    }

    /// 强制立即睡眠。pmset sleepnow 走 power management 路径,能绕过 idle 声明。
    /// 返回 true 才表示请求真的发出去了(退出码 0;不保证 powerd 一定接受)。
    /// 注意:若系统 SleepDisabled=1,连 root 也会被拒 —— 调用方应先调 resetDisableSleep()。
    @discardableResult
    static func forceSleep() -> Bool {
        // pmset 把 "Unable to sleep system" 写到 stdout(stderr 是空的),runProcess 两路都抓
        let (code, out) = runProcess("/usr/bin/pmset", ["sleepnow"])
        if code != 0 {
            NSLog("ShutEye: pmset sleepnow 退出码 \(code) \(out)")
            Log.write("pmset 失败(退出码 \(code)): \(out)")
            return false
        }
        return true
    }
}
