import Foundation
import IOKit
import AppKit

/// 监听 IOPMrootDomain 的 interest 通知,在「盖子合上」时发出一次「考虑睡眠」信号。
///
/// 设计(经两轮 Codex 对抗审查):
/// - 不再自己判断「该不该睡一次」。凡是「合盖状态」出现的时机(合盖上升沿、唤醒时仍合盖),
///   都发一次 onShouldSleep,由 AppDelegate 用**冷却时间**统一裁决。
/// - 冷却时间同时解决两个对立风险:既不会唤醒后一直醒着(round2 P1),
///   也不会 sleep→wake→sleep 高频抖动(round1 P1)。
/// - `generation` 作废睡前排队的过期延迟任务;唤醒时 +1。
final class ClamshellMonitor {

    /// 「现在是合盖状态,考虑睡眠」。AppDelegate 再判守卫 + 冷却 + 执行。
    var onShouldSleep: (() -> Void)?

    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var rootDomain: io_service_t = 0

    private var lastClosed = false
    private var generation = 0
    private var started = false
    private let settleDelay: TimeInterval = 1.5

    func start() {
        guard !started else { return }

        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault,
                                                 IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else {
            Log.write("找不到 IOPMrootDomain,合盖监听未启动")
            return
        }

        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = notifyPort else {
            IOObjectRelease(rootDomain); rootDomain = 0
            return
        }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceInterestCallback = { (refcon, _, _, _) in
            guard let refcon = refcon else { return }
            Unmanaged<ClamshellMonitor>.fromOpaque(refcon)
                .takeUnretainedValue()
                .handleInterest()
        }

        let kr = IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest,
                                                  callback, refcon, &notifier)
        guard kr == KERN_SUCCESS else {
            Log.write("IOServiceAddInterestNotification 失败: \(kr),合盖监听未启动")
            IONotificationPortDestroy(port); notifyPort = nil
            IOObjectRelease(rootDomain); rootDomain = 0
            return
        }

        lastClosed = PowerInfo.clamshellClosed()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        started = true
    }

    @objc private func systemDidWake() {
        generation &+= 1                       // 作废睡前排队的过期延迟任务
        let closed = PowerInfo.clamshellClosed()
        lastClosed = closed
        // 唤醒时仍合盖 = 外因唤醒(Power Nap/蓝牙/电源)→ 该再睡回去(下游冷却防抖)
        if closed { scheduleSleep() }
    }

    private func handleInterest() {
        let closed = PowerInfo.clamshellClosed()
        defer { lastClosed = closed }
        if !closed { generation &+= 1; return }   // 开盖:作废待执行任务
        guard !lastClosed else { return }         // 只在「开→合」上升沿
        scheduleSleep()
    }

    private func scheduleSleep() {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            guard let self = self, gen == self.generation, PowerInfo.clamshellClosed() else { return }
            self.onShouldSleep?()
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if notifier != 0 { IOObjectRelease(notifier) }
        if rootDomain != 0 { IOObjectRelease(rootDomain) }
        if let port = notifyPort { IONotificationPortDestroy(port) }
    }
}
