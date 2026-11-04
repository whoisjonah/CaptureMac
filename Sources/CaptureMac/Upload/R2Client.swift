import CryptoKit
import Foundation
import Security

enum Keychain {
    private static let service = "CaptureMac"

    static func read(_ account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, for account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}

struct UploadError: LocalizedError {
    let errorDescription: String?
}

final class R2Client {
    static let secretAccount = "r2-secret-access-key"

    let settings: R2Settings
    private let signer: Signer

    init(settings: R2Settings) throws {
        guard settings.isComplete else {
            throw UploadError(errorDescription: "set up r2 in settings first")
        }
        guard let secret = Keychain.read(Self.secretAccount), !secret.isEmpty else {
            throw UploadError(errorDescription: "r2 secret key is missing (settings > upload)")
        }
        self.settings = settings
        signer = Signer(accessKeyID: settings.accessKeyID, secret: secret)
    }

    func upload(_ file: URL, key: String, progress: @escaping (Double) -> Void = { _ in }) async throws -> URL {
        let hash = try await Task.detached { try Signer.hashFile(file) }.value
        var request = URLRequest(url: try objectURL(key))
        request.httpMethod = "PUT"
        request.setValue(contentType(for: file), forHTTPHeaderField: "Content-Type")
        signer.sign(&request, payloadHash: hash)

        let (data, response) = try await URLSession.shared.upload(
            for: request, fromFile: file, delegate: ProgressDelegate(progress))
        try validate(response, data)
        return try publicURL(for: key)
    }

    func test() async throws {
        let key = "\(folderPrefix)capturemac-connection-test.txt"
        let body = Data("ok".utf8)
        var put = URLRequest(url: try objectURL(key))
        put.httpMethod = "PUT"
        put.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        signer.sign(&put, payloadHash: Signer.hex(SHA256.hash(data: body)))
        let (data, response) = try await URLSession.shared.upload(for: put, from: body)
        try validate(response, data)

        var delete = URLRequest(url: try objectURL(key))
        delete.httpMethod = "DELETE"
        signer.sign(&delete, payloadHash: Signer.hex(SHA256.hash(data: Data())))
        _ = try? await URLSession.shared.data(for: delete)
    }

    static func makeKey(for file: URL, folder: String) -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let slug = String((0..<10).map { _ in alphabet[Int.random(in: alphabet.indices)] })
        let prefix = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let name = "\(slug).\(file.pathExtension.lowercased())"
        return prefix.isEmpty ? name : "\(prefix)/\(name)"
    }

    private var folderPrefix: String {
        let prefix = settings.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return prefix.isEmpty ? "" : prefix + "/"
    }

    private func objectURL(_ key: String) throws -> URL {
        guard let endpoint = URL(string: "https://\(settings.accountID).r2.cloudflarestorage.com") else {
            throw UploadError(errorDescription: "the r2 account id isn't valid")
        }
        return endpoint.appendingPathComponent(settings.bucket).appendingPathComponent(key)
    }

    private func publicURL(for key: String) throws -> URL {
        var base = settings.publicURL.trimmingCharacters(in: .whitespaces)
        if !base.hasPrefix("http") { base = "https://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base) else {
            throw UploadError(errorDescription: "the public url isn't valid")
        }
        return url.appendingPathComponent(key)
    }

    private func contentType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "mov": "video/quicktime"
        case "mp4", "m4v": "video/mp4"
        default: "application/octet-stream"
        }
    }

    private func validate(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = body.range(of: "<Code>(.*?)</Code>", options: .regularExpression).map {
                String(body[$0]).replacingOccurrences(of: "<Code>", with: "").replacingOccurrences(
                    of: "</Code>", with: "")
            }
            throw UploadError(errorDescription: "r2 said no (\(http.statusCode)\(code.map { ", \($0)" } ?? ""))")
        }
    }
}

private final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
    let handler: (Double) -> Void

    init(_ handler: @escaping (Double) -> Void) {
        self.handler = handler
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        handler(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
