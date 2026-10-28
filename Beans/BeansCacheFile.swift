import Foundation

/// 元数据缓存的落盘位置。
///
/// 这些缓存是几十 KB 到几 MB 的整份 JSON。放在 UserDefaults 里，每写一次都要把整份
/// 偏好文件重写，删一个键同样要走一遍偏好进程——数据一大，`removeObject` 会长时间不返回，
/// 一键清理就卡在那里（2026-10-27 定位）。所以载荷一律写成 Caches 下的文件：
/// 写是原子写文件，清是删文件，都不碰偏好。
enum BeansCacheFile {
    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    static func url(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let file = url(name)
        guard (try? BeansCacheFiles.isRegularFile(file, under: root)) == true,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// 返回是否写成功；调用方据此决定能不能删旧的偏好键。
    @discardableResult
    static func write<T: Encodable>(_ value: T, to name: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        do {
            try data.write(to: url(name), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func remove(_ name: String) {
        try? BeansCacheFiles.removeFile(url(name), under: root)
    }

    static func bytes(_ name: String) -> Int64 {
        (try? BeansCacheFiles.fileBytes(url(name), under: root)) ?? 0
    }
}
