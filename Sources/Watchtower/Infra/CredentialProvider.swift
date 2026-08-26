import Foundation

/// Resolves AWS credentials from `~/.aws`, exactly like the CLI's shared-config chain.
///
/// Deliberate omissions: no environment variables, no EC2/ECS metadata, no SSO. A GUI app
/// launched at login inherits none of the shell environment, so reading `AWS_PROFILE` or
/// `AWS_REGION` would work when launched from a terminal and silently fail at login — the
/// worst possible failure mode. Profile and region are therefore always explicit.
actor CredentialProvider {

    enum Failure: LocalizedError {
        case noCredentialsFile(String)
        case noSuchProfile(String, available: [String])
        case missingKeys(String)
        case assumeRoleFailed(String)

        var errorDescription: String? {
            switch self {
            case .noCredentialsFile(let path):
                return "No AWS credentials file at \(path)"
            case .noSuchProfile(let name, let available):
                return "Profile “\(name)” not found in ~/.aws (available: \(available.sorted().joined(separator: ", ")))"
            case .missingKeys(let name):
                return "Profile “\(name)” has no aws_access_key_id / aws_secret_access_key"
            case .assumeRoleFailed(let detail):
                return "AssumeRole failed: \(detail)"
            }
        }
    }

    /// How the current credentials were obtained — surfaced in the panel so it is always
    /// obvious which identity the app is running as.
    struct Resolution {
        var profile: String
        var region: String
        var roleArn: String?
        var isAssumedRole: Bool { roleArn != nil }
        var description: String {
            roleArn.map { "\(profile) → \($0.split(separator: "/").last.map(String.init) ?? $0)" } ?? profile
        }
    }

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var cached: SigV4.Credentials?
    private(set) var resolution: Resolution?

    private var configURL: URL { home.appendingPathComponent(".aws/config") }
    private var credentialsURL: URL { home.appendingPathComponent(".aws/credentials") }

    /// Profile names present in either file, for the panel's picker.
    func availableProfiles() -> [String] {
        var names = Set<String>()
        if let ini = try? INIFile(contentsOf: credentialsURL) { names.formUnion(ini.profileNames) }
        if let ini = try? INIFile(contentsOf: configURL) { names.formUnion(ini.profileNames) }
        return names.sorted()
    }

    func region(for profileName: String) -> String {
        (try? INIFile(contentsOf: configURL))?.profile(profileName)?["region"] ?? "us-east-1"
    }

    func invalidate() { cached = nil }

    /// Returns valid credentials, assuming a role if the profile is configured for one.
    func credentials(profile profileName: String) async throws -> SigV4.Credentials {
        if let cached, !cached.isExpired { return cached }

        guard FileManager.default.fileExists(atPath: credentialsURL.path)
                || FileManager.default.fileExists(atPath: configURL.path) else {
            throw Failure.noCredentialsFile(credentialsURL.path)
        }

        let credentialsINI = try? INIFile(contentsOf: credentialsURL)
        let configINI = try? INIFile(contentsOf: configURL)

        let settings = (configINI?.profile(profileName) ?? [:])
            .merging(credentialsINI?.profile(profileName) ?? [:]) { _, new in new }

        guard !settings.isEmpty else {
            throw Failure.noSuchProfile(profileName, available: availableProfiles())
        }

        let regionName = settings["region"] ?? region(for: profileName)

        // Role profile: static keys from source_profile, then STS AssumeRole.
        if let roleArn = settings["role_arn"] {
            let sourceName = settings["source_profile"] ?? "default"
            let sourceSettings = (configINI?.profile(sourceName) ?? [:])
                .merging(credentialsINI?.profile(sourceName) ?? [:]) { _, new in new }
            let base = try staticCredentials(from: sourceSettings, profileName: sourceName)
            let assumed = try await assumeRole(roleArn: roleArn,
                                               sessionName: settings["role_session_name"] ?? "watchtower",
                                               base: base,
                                               region: regionName)
            cached = assumed
            resolution = Resolution(profile: profileName, region: regionName, roleArn: roleArn)
            return assumed
        }

        let creds = try staticCredentials(from: settings, profileName: profileName)
        cached = creds
        resolution = Resolution(profile: profileName, region: regionName, roleArn: nil)
        return creds
    }

    private func staticCredentials(from settings: [String: String],
                                   profileName: String) throws -> SigV4.Credentials {
        guard let key = settings["aws_access_key_id"],
              let secret = settings["aws_secret_access_key"] else {
            throw Failure.missingKeys(profileName)
        }
        return SigV4.Credentials(accessKeyId: key,
                                 secretAccessKey: secret,
                                 sessionToken: settings["aws_session_token"],
                                 expiration: nil)
    }

    // MARK: - STS AssumeRole (Query protocol, XML response)

    private func assumeRole(roleArn: String,
                            sessionName: String,
                            base: SigV4.Credentials,
                            region: String) async throws -> SigV4.Credentials {
        let body = [
            "Action=AssumeRole",
            "Version=2011-06-15",
            "RoleArn=\(QueryEncoding.escape(roleArn))",
            "RoleSessionName=\(QueryEncoding.escape(sessionName))",
            "DurationSeconds=3600"
        ].joined(separator: "&")

        var request = URLRequest(url: URL(string: "https://sts.amazonaws.com/")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                         forHTTPHeaderField: "Content-Type")
        // STS is global; sign against us-east-1 for the global endpoint.
        SigV4.sign(&request, service: "sts", region: "us-east-1", credentials: base)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = XMLNode.parse(data)?.find("Message")?.trimmed
                ?? String(data: data, encoding: .utf8)?.prefix(200).description
                ?? "unknown error"
            throw Failure.assumeRoleFailed(detail)
        }
        guard let root = XMLNode.parse(data),
              let creds = root.find("Credentials"),
              let key = creds.first("AccessKeyId")?.trimmed,
              let secret = creds.first("SecretAccessKey")?.trimmed,
              let token = creds.first("SessionToken")?.trimmed else {
            throw Failure.assumeRoleFailed("unparseable STS response")
        }
        var expiry: Date?
        if let raw = creds.first("Expiration")?.trimmed {
            expiry = AWSDate.parse(raw)
        }

        return SigV4.Credentials(accessKeyId: key,
                                 secretAccessKey: secret,
                                 sessionToken: token,
                                 expiration: expiry)
    }
}

enum QueryEncoding {
    /// RFC 3986 escaping. `CharacterSet.urlQueryAllowed` is too permissive for SigV4.
    static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
