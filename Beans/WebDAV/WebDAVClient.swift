import Foundation

// Reconstructed protocol transport. Limits and a versioned backup format are explicit recovery decisions.
struct WebDAVClient {
    let connection: WebDAVConnection
    private let password: String
    let root: URL

    init(connection: WebDAVConnection, password: String? = nil) throws {
        self.connection = connection
        root = try WebDAVPaths.root(for: connection)
        if let password { self.password = password }
        else {
            guard let stored = try WebDAVCredentialStore.password(id: connection.id) else { throw WebDAVError.missingConnection }
            self.password = stored
        }
    }

    func list(directory: URL? = nil) async throws -> [WebDAVEntry] {
        let validated = try WebDAVPaths.validate(directory ?? root, root: root)
        let url = validated.hasDirectoryPath ? validated : validated.appendingPathComponent("", isDirectory: true)
        let xml = #"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>"#
        var request = try request(method: "PROPFIND", url: url)
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(xml.utf8)
        let file = try await WebDAVTransfer(root: root, limit: 8 * 1024 * 1024).run(request)
        defer { try? FileManager.default.removeItem(at: file) }
        let payload = try Data(contentsOf: file)
        // 200 + HTML（例如把普通网站地址当 WebDAV 填）会解析出空目录，看着像"连上了但没文件"。
        // 只有确实回了 multistatus 才当 WebDAV 处理。
        let head = String(decoding: payload.prefix(4096), as: UTF8.self).lowercased()
        guard head.contains("multistatus") else { throw WebDAVError.invalidListing }
        return try WebDAVListingParser.parse(payload, directory: url, root: root)
    }

    func download(_ url: URL, limit: Int64) async throws -> URL {
        try await WebDAVTransfer(root: root, limit: limit).run(request(method: "GET", url: url))
    }

    func downloadBackup(_ url: URL) async throws -> Data {
        let file = try await download(url, limit: 16 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        return try Data(contentsOf: file)
    }

    func uploadBackup(_ data: Data, fileName: String) async throws -> URL {
        guard data.count <= 16 * 1024 * 1024 else { throw WebDAVError.tooLarge }
        let url = try WebDAVPaths.fileURL(path: fileName, root: root)
        var request = try request(method: "PUT", url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let responseFile = try await WebDAVTransfer(root: root, limit: 1024 * 1024).run(request)
        try? FileManager.default.removeItem(at: responseFile)
        // Read-back is evidence-backed; compare actual bytes before displaying success.
        let verified = try await downloadBackup(url)
        guard verified == data else { throw WebDAVError.invalidBackup }
        return url
    }

    private func request(method: String, url: URL) throws -> URLRequest {
        var request = URLRequest(url: try WebDAVPaths.validate(url, root: root))
        request.httpMethod = method
        let credential = Data((connection.username + ":" + password).utf8).base64EncodedString()
        request.setValue("Basic " + credential, forHTTPHeaderField: "Authorization")
        return request
    }
}
