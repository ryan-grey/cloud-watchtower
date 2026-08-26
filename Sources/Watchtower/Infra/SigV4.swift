import Foundation
import CryptoKit

/// Minimal AWS Signature Version 4 signer.
///
/// This exists instead of the AWS SDK for Swift: that package is a 2.3 GB / ~923k-object
/// repository, and a full `swift package resolve` ran for 110 minutes on this machine before
/// dying mid-clone. Watchtower needs five API calls, all of which are plain HTTPS POSTs, so
/// signing them directly is both smaller and auditable end to end.
enum SigV4 {

    struct Credentials {
        var accessKeyId: String
        var secretAccessKey: String
        var sessionToken: String?
        /// nil for static keys; set for STS-derived (assume-role) credentials.
        var expiration: Date?

        var isExpired: Bool {
            guard let expiration else { return false }
            // Refresh a few minutes early so a request never races the expiry.
            return Date() >= expiration.addingTimeInterval(-5 * 60)
        }
    }

    /// Signs `request` in place. `body` must already be set as httpBody.
    static func sign(_ request: inout URLRequest,
                     service: String,
                     region: String,
                     credentials: Credentials,
                     now: Date = Date()) {

        guard let url = request.url, let host = url.host else { return }

        let amzDate = Format.amzDate(now)          // 20260826T104500Z
        let dateStamp = Format.dateStamp(now)      // 20260826
        let payload = request.httpBody ?? Data()
        let payloadHash = hex(SHA256.hash(data: payload))

        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")
        if let token = credentials.sessionToken {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        // --- Canonical request -------------------------------------------------
        let headers = (request.allHTTPHeaderFields ?? [:])
            .map { (name: $0.key.lowercased(), value: $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.name < $1.name }

        let canonicalHeaders = headers.map { "\($0.name):\($0.value)\n" }.joined()
        let signedHeaders = headers.map(\.name).joined(separator: ";")

        let canonicalURI = url.path.isEmpty ? "/" : url.path
        let canonicalQuery = url.query ?? ""

        let canonicalRequest = [
            request.httpMethod ?? "POST",
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        // --- String to sign ----------------------------------------------------
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            hex(SHA256.hash(data: Data(canonicalRequest.utf8)))
        ].joined(separator: "\n")

        // --- Signature ---------------------------------------------------------
        let kDate = hmac(Data("AWS4\(credentials.secretAccessKey)".utf8), Data(dateStamp.utf8))
        let kRegion = hmac(kDate, Data(region.utf8))
        let kService = hmac(kRegion, Data(service.utf8))
        let kSigning = hmac(kService, Data("aws4_request".utf8))
        let signature = hex(hmac(kSigning, Data(stringToSign.utf8)))

        let authorization = "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKeyId)/\(scope), "
            + "SignedHeaders=\(signedHeaders), "
            + "Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    // MARK: - Primitives

    private static func hmac(_ key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func hex(_ digest: SHA256Digest) -> String { hex(Array(digest)) }
    private static func hex(_ data: Data) -> String { hex(Array(data)) }

    enum Format {
        private static func formatter(_ pattern: String) -> DateFormatter {
            let f = DateFormatter()
            f.dateFormat = pattern
            f.timeZone = TimeZone(identifier: "UTC")
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }
        static let amz = formatter("yyyyMMdd'T'HHmmss'Z'")
        static let stamp = formatter("yyyyMMdd")
        static let iso = formatter("yyyy-MM-dd'T'HH:mm:ss'Z'")
        static let day = formatter("yyyy-MM-dd")

        static func amzDate(_ d: Date) -> String { amz.string(from: d) }
        static func dateStamp(_ d: Date) -> String { stamp.string(from: d) }
        static func iso8601(_ d: Date) -> String { iso.string(from: d) }
        static func yyyymmdd(_ d: Date) -> String { day.string(from: d) }
    }
}
