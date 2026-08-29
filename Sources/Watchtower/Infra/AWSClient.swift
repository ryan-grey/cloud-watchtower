import Foundation

struct AWSError: LocalizedError {
    var code: String
    var message: String
    var httpStatus: Int?

    var errorDescription: String? {
        // "AccessDeniedException" reads better than "AccessDeniedException: <200 chars of ARN>"
        // in a 320pt panel, but the detail matters when it is a real failure.
        message.isEmpty ? code : "\(code): \(message)"
    }

    /// A denial is a configuration problem, not a transient one — never worth retrying.
    var isPermissionProblem: Bool {
        code.localizedCaseInsensitiveContains("AccessDenied")
            || code.localizedCaseInsensitiveContains("UnrecognizedClient")
            || code.localizedCaseInsensitiveContains("InvalidClientTokenId")
            || code.localizedCaseInsensitiveContains("SignatureDoesNotMatch")
    }
}

/// Issues signed requests to the handful of AWS APIs Watchtower needs.
actor AWSClient {

    private let credentials: CredentialProvider
    private let meter: CallMeter
    private let session: URLSession
    /// Only a fallback for callers with no target in hand (the Cost Explorer button, the
    /// footer). Every polled call names its target's own profile, because Pro can watch two
    /// accounts at once and a single ambient profile would silently sign for the wrong one.
    var defaultProfile: String

    init(profileName: String, credentials: CredentialProvider, meter: CallMeter) {
        self.defaultProfile = profileName
        self.credentials = credentials
        self.meter = meter
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func setDefaultProfile(_ name: String) async {
        defaultProfile = name
    }

    func resolution(for profile: String) async -> CredentialProvider.Resolution? {
        await credentials.resolution(for: profile)
    }

    // MARK: - Query protocol (CloudWatch)

    func query(service: String,
               host: String,
               region: String,
               profile: String? = nil,
               api: String,
               version: String,
               params: [String: String],
               billedMetrics: Int = 0) async throws -> XMLNode {

        var pairs = params
        pairs["Action"] = api
        pairs["Version"] = version
        let body = pairs.keys.sorted()
            .map { "\(QueryEncoding.escape($0))=\(QueryEncoding.escape(pairs[$0]!))" }
            .joined(separator: "&")

        var request = URLRequest(url: URL(string: "https://\(host)/")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                         forHTTPHeaderField: "Content-Type")

        let data = try await send(&request, service: service, region: region,
                                  profile: profile ?? defaultProfile,
                                  api: api, billedMetrics: billedMetrics, isJSON: false)
        guard let root = XMLNode.parse(data) else {
            throw AWSError(code: "MalformedResponse", message: "could not parse XML from \(api)")
        }
        return root
    }

    // MARK: - JSON protocol (Budgets, Cost Explorer)

    func json(service: String,
              host: String,
              region: String,
              profile: String? = nil,
              target: String,
              api: String,
              payload: [String: Any]) async throws -> [String: Any] {

        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: URL(string: "https://\(host)/")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue(target, forHTTPHeaderField: "X-Amz-Target")

        let data = try await send(&request, service: service, region: region,
                                  profile: profile ?? defaultProfile,
                                  api: api, billedMetrics: 0, isJSON: true)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AWSError(code: "MalformedResponse", message: "could not parse JSON from \(api)")
        }
        return object
    }

    // MARK: - Transport

    private func send(_ request: inout URLRequest,
                      service: String,
                      region: String,
                      profile: String,
                      api: String,
                      billedMetrics: Int,
                      isJSON: Bool) async throws -> Data {

        let creds = try await credentials.credentials(profile: profile)
        SigV4.sign(&request, service: service, region: region, credentials: creds)

        // Count the call before awaiting the response: a request that is sent and then fails
        // has still been billed. Under-counting would flatter the cost report.
        await meter.record(api, metrics: billedMetrics)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AWSError(code: "NoResponse", message: "no HTTP response for \(api)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw parseError(data, status: http.statusCode, isJSON: isJSON)
        }
        return data
    }

    private func parseError(_ data: Data, status: Int, isJSON: Bool) -> AWSError {
        if isJSON, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // JSON errors put the code in __type, sometimes prefixed with a namespace URI.
            let rawType = (object["__type"] as? String) ?? "HTTP\(status)"
            let code = rawType.split(separator: "#").last.map(String.init) ?? rawType
            let message = (object["message"] as? String) ?? (object["Message"] as? String) ?? ""
            return AWSError(code: code, message: message, httpStatus: status)
        }
        if let root = XMLNode.parse(data) {
            let code = root.find("Code")?.trimmed ?? "HTTP\(status)"
            let message = root.find("Message")?.trimmed ?? ""
            return AWSError(code: code, message: message, httpStatus: status)
        }
        return AWSError(code: "HTTP\(status)",
                        message: String(data: data, encoding: .utf8)?.prefix(200).description ?? "",
                        httpStatus: status)
    }
}
