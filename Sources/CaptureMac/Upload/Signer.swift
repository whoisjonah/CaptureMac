import CryptoKit
import Foundation

struct Signer {
    var accessKeyID: String
    var secret: String
    var region = "auto"
    var service = "s3"

    static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    func sign(_ request: inout URLRequest, payloadHash: String, date: Date = .now) {
        guard let url = request.url, let host = url.host else { return }
        let stamp = Self.timestamp(date)
        let day = String(stamp.prefix(8))

        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(stamp, forHTTPHeaderField: "x-amz-date")

        var headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { result, pair in
            result[pair.key.lowercased()] = pair.value.trimmingCharacters(in: .whitespaces)
        }
        headers["host"] = url.port.map { "\(host):\($0)" } ?? host
        let names = headers.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let canonicalHeaders = names.map { "\($0):\(headers[$0, default: ""])\n" }.joined()

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            Self.canonicalPath(url),
            Self.canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", stamp, scope, Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8)))]
            .joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func canonicalPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(String($0)) }
            .joined(separator: "/")
    }

    static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pairs: [(String, String)] = items.map { item in
            (encode(item.name), encode(item.value ?? ""))
        }
        return
            pairs
            .sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }
}
