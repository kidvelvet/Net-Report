import Foundation

/// Errors surfaced by the QRZ XML API client.
public enum QRZError: Error, LocalizedError {
    case login(String)
    case lookup(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .login(let detail):   return "QRZ login failed: \(detail)"
        case .lookup(let detail):  return "QRZ lookup failed: \(detail)"
        case .network(let detail): return "QRZ network error: \(detail)"
        }
    }
}

/// A QRZ.com subscriber login. There is no built-in account: each operator signs
/// in with their own credentials, which the app can store in the macOS Keychain.
public struct QRZCredentials: Sendable, Equatable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// Credentials supplied via the `QRZ_USERNAME` / `QRZ_PASSWORD` environment
    /// variables, for headless/testing use. Nil when either is unset.
    public static func fromEnvironment() -> QRZCredentials? {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["QRZ_USERNAME"], !user.isEmpty,
              let pass = env["QRZ_PASSWORD"], !pass.isEmpty else { return nil }
        return QRZCredentials(username: user, password: pass)
    }
}

/// Talks to the QRZ XML data service: logs in for a session key, then resolves
/// call signs to `HamRecord`s. Ported from `QRZClient` in `ham_lookup.py`,
/// including the transparent re-login on session timeout.
///
/// An `actor` so the cached session key is mutated safely across concurrent
/// lookups.
public actor QRZClient {
    private static let apiURL = URL(string: "https://xmldata.qrz.com/xml/current/")!
    private static let agent = "net_report_macos_1.0"

    private let username: String
    private let password: String
    private var sessionKey = ""
    private let session: URLSession

    public init(username: String, password: String, session: URLSession = .shared) {
        self.username = username
        self.password = password
        self.session = session
    }

    public init(credentials: QRZCredentials, session: URLSession = .shared) {
        self.init(username: credentials.username,
                  password: credentials.password,
                  session: session)
    }

    // MARK: - Public API

    /// Authenticate and cache a session key. Safe to call repeatedly.
    public func login() async throws {
        let values = try await request([
            "username": username,
            "password": password,
            "agent": Self.agent,
        ])
        let key = values["Key"] ?? ""
        guard !key.isEmpty else {
            let detail = values["Error"] ?? values["Message"] ?? "No session key returned."
            throw QRZError.login(Self.sanitized(detail))
        }
        sessionKey = key
    }

    /// Look up a call sign. Returns `nil` when QRZ reports "not found".
    /// Re-authenticates once transparently if the session has expired.
    public func lookup(callSign: String) async throws -> HamRecord? {
        if sessionKey.isEmpty {
            try await login()
        }

        var values = try await request(["s": sessionKey, "callsign": callSign])
        var error = values["Error"] ?? ""

        let lowered = error.lowercased()
        if lowered.contains("session timeout") || lowered.contains("invalid session key") {
            try await login()
            values = try await request(["s": sessionKey, "callsign": callSign])
            error = values["Error"] ?? ""
        }

        if !error.isEmpty {
            if error.lowercased().contains("not found") {
                return nil
            }
            var detail = error
            if let message = values["Message"], !message.isEmpty {
                detail += " (\(message))"
            }
            throw QRZError.lookup(Self.sanitized(detail))
        }

        // No <Callsign> element means nothing matched.
        guard values["__hasCallsign"] == "1" else { return nil }

        // QRZ returns the given name in <fname> and the surname in <name>.
        let fname = values["fname"] ?? ""
        let lname = values["name"] ?? ""
        let fullName = "\(fname) \(lname)".trimmingCharacters(in: .whitespaces)

        return HamRecord(
            callSign: values["call"]?.nilIfEmpty ?? callSign.uppercased(),
            name: fullName.nilIfEmpty ?? "Unknown",
            firstName: fname,
            lastName: lname,
            street: values["addr1"]?.nilIfEmpty ?? "Unknown",
            city: values["addr2"]?.nilIfEmpty ?? "Unknown",
            county: values["county"]?.nilIfEmpty ?? "Unknown",
            state: values["state"]?.nilIfEmpty ?? "Unknown"
        )
    }

    // MARK: - Transport

    private func request(_ params: [String: String]) async throws -> [String: String] {
        var req = URLRequest(url: Self.apiURL, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(params).data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            // The redirect blocker matters because this POST carries the
            // password: a 307/308 preserves method *and* body, so a spoofed or
            // compromised endpoint could otherwise bounce the credentials to a
            // host of its choosing.
            (data, response) = try await session.data(for: req, delegate: Self.redirectBlocker)
        } catch {
            throw QRZError.network(error.localizedDescription)
        }

        // Don't feed an error page to the XML parser and report it as a missing
        // session key — say what actually happened.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw QRZError.network("QRZ returned HTTP \(http.statusCode).")
        }
        return QRZResponseParser().parse(data)
    }

    private static let redirectBlocker = RedirectBlocker()

    /// Collapse and cap text that came from the server before it is shown in a
    /// native alert, so a hostile endpoint can't paint multi-line phishing text
    /// inside the app's own trusted chrome.
    private static func sanitized(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.count > 200 ? String(flattened.prefix(200)) + "…" : flattened
    }

    /// Unreserved characters per RFC 3986. Built once: assembling a CharacterSet
    /// is not cheap, and this runs for every field of every request.
    private static let unreserved: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static func formEncode(_ params: [String: String]) -> String {
        let allowed = unreserved
        return params
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Refuses every HTTP redirect. The QRZ login POST carries the operator's
/// password in its body, and a 307/308 redirect preserves the body — so
/// following redirects would let a hostile endpoint harvest the credentials.
/// QRZ's XML service does not legitimately redirect.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)   // nil = do not follow
    }
}
