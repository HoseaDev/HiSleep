import Foundation

/// 把事件追加写到 ~/Library/Logs/HiSleep.log,同时走 NSLog。
/// 合盖后看不到屏幕,事后用这个文件确认到底发生了什么。
enum Log {

    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return dir.appendingPathComponent("HiSleep.log")
    }()

    private static let queue = DispatchQueue(label: "com.hosea.hisleep.log")

    // DateFormatter 不是线程安全的 → 只在串行队列内使用。
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// 异步写。普通事件用这个,不阻塞调用方。
    static func write(_ message: String) {
        NSLog("HiSleep: \(message)")
        queue.async { append(message) }
    }

    /// 同步写。合盖→睡眠这种关键路径用这个:确保日志在机器睡着前已经落盘。
    static func writeSync(_ message: String) {
        NSLog("HiSleep: \(message)")
        queue.sync { append(message) }
    }

    /// 必须在 `queue` 上调用(formatter + 文件写入都在此串行化)。
    private static func append(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        let path = fileURL.path

        if !fm.fileExists(atPath: path) {
            if !fm.createFile(atPath: path, contents: data) {
                NSLog("HiSleep: 无法创建日志文件 \(path)")
            }
            return
        }
        // 文件可能在 fileExists 之后被删/轮转:写句柄失败就兜底重建。
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
