import Foundation
import SwiftUI

// MARK: - 日志级别

enum BeansLogLevel: String, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
    case fatal = "FATAL"

    var tint: Color {
        switch self {
        case .debug: return .secondary
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        case .fatal: return .red
        }
    }
}

// MARK: - 单条日志

struct BeansLogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: BeansLogLevel
    let message: String
}

// MARK: - 全局日志中心

/// 全局日志中心：内存环形缓存（供 App 内查看）+ 文件持久化（Application Support/BeansDiagnostics/beans-日期.log，可导出分享）。
/// 任意线程可调用 log()，界面更新自动切回主线程。
final class BeansLogger: ObservableObject {

    static let shared = BeansLogger()

    @Published private(set) var entries: [BeansLogEntry] = []

    private let maxEntries = 5000
    private let maxLogFileBytes = 10 * 1024 * 1024
    private let lock = NSLock()
    private let diskQueue = DispatchQueue(label: "Beans.Logger.disk", qos: .utility)
    private let directory: URL
    private var generation: UInt64 = 0
    private var recentEntries: [BeansLogEntry] = []

    private static let lineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    init(directory: URL = BeansDiagnostics.logDirectoryURL, logStartup: Bool = true) {
        self.directory = directory
        if logStartup { log("Beans Music 启动（版本 \(Self.appVersion)）", level: .info) }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    /// 记录一条日志（任意线程可调用）
    func log(_ message: String, level: BeansLogLevel = .debug) {
        let entry = BeansLogEntry(date: Date(), level: level, message: message)
        lock.lock()
        recentEntries.append(entry)
        if recentEntries.count > maxEntries {
            recentEntries.removeFirst(recentEntries.count - maxEntries)
        }
        let snapshot = recentEntries
        let token = generation
        // Enqueue while holding the same lock as clear, preserving log/clear order.
        diskQueue.async { [self] in write(entry.line) }
        lock.unlock()
        publish(snapshot, token: token)
    }

    /// 全部日志文本（按时间正序）
    var fullText: String {
        lock.lock()
        let snapshot = recentEntries
        lock.unlock()
        return snapshot.map(\.line).joined(separator: "\n")
    }

    /// Existing UI entry point; cache management uses the throwing async API below.
    func clear() {
        Task {
            do { try await clearCache() }
            catch { log("日志清理失败：\(error.localizedDescription)", level: .error) }
        }
    }

    func clearCache() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            diskQueue.async { [self] in
                lock.lock()
                defer { lock.unlock() }
                do {
                    try BeansCacheFiles.clearContents(of: directory, under: directory.deletingLastPathComponent())
                    recentEntries.removeAll()
                    generation &+= 1
                    publish([], token: generation)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func cacheDiskBytes() async throws -> Int64 {
        try await withCheckedThrowingContinuation { continuation in
            diskQueue.async { [self] in
                do { continuation.resume(returning: try BeansCacheFiles.bytes(in: directory, under: directory.deletingLastPathComponent())) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func publish(_ snapshot: [BeansLogEntry], token: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = self.generation == token
            self.lock.unlock()
            if isCurrent { self.entries = snapshot }
        }
    }

    // MARK: - 文件持久化 (diskQueue only)

    private var currentFileURL: URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return directory.appendingPathComponent("beans-\(formatter.string(from: Date())).log")
    }

    /// 导出日志文件（不存在则先生成一份完整日志）
    func exportLogURL() -> URL {
        let text = fullText
        return diskQueue.sync {
            let url = currentFileURL
            guard (try? BeansCacheFiles.validateDirectory(directory, under: directory.deletingLastPathComponent())) != nil else { return url }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            return url
        }
    }

    private func write(_ line: String) {
        guard (try? BeansCacheFiles.validateDirectory(directory, under: directory.deletingLastPathComponent())) != nil else { return }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return }
        let url = currentFileURL
        // Refuse a symlink at the final log file too.
        if let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
           type != .typeRegular { return }
        // 单日日志过大时轮转到 .1，避免无限膨胀
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if fileSize > maxLogFileBytes {
            let rotated = url.deletingPathExtension().appendingPathExtension("1.log")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
        }
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(payload)
        } else {
            try? payload.write(to: url, options: .atomic)
        }
    }
}

extension BeansLogEntry {
    var line: String {
        "[\(BeansLogger.dateString(date))] [\(level.rawValue)] \(message)"
    }
}

