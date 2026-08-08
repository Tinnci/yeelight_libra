import Foundation

/// Minimal unbuffered file logger (writes to ~/yeelight_libra.log).
enum Logger {
    private static let lock = NSLock()
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("yeelight_libra.log")

    static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(Date()): \(message)\n"
        if let data = line.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? (line.data(using: .utf8))?.write(to: url)
        }
    }
}
