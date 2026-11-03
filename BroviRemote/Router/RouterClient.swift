import Foundation

struct RouterError: LocalizedError {
    let code: String?
    let message: String

    var errorDescription: String? {
        if let code { return "\(message) (Code \(code))" }
        return message
    }

    static let tokenErrors: Set<String> = ["125001", "125002", "125003"]

    static func fromCode(_ code: String) -> RouterError {
        let known: [String: String] = [
            "100002": "Funktion wird vom Router nicht unterstützt",
            "100003": "Keine Berechtigung – bitte neu anmelden",
            "100004": "Router ist beschäftigt",
            "100005": "Ungültige Parameter",
            "108001": "Benutzername falsch",
            "108002": "Passwort falsch",
            "108003": "Bereits angemeldet",
            "108006": "Benutzername oder Passwort falsch",
            "108007": "Zu viele Anmeldeversuche – bitte warten",
            "125001": "Ungültiges Token",
            "125002": "Ungültige Sitzung",
            "125003": "Sitzungs-Token abgelaufen",
        ]
        return RouterError(code: code, message: known[code] ?? "Router-Fehler")
    }
}

/// Client für die HiLink-Web-API (Huawei-basierte Router wie der Brovi H153-381).
actor RouterClient {
    let baseURL: URL
    private let session: URLSession
    private var sessionID: String?
    private var tokens: [String] = []

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    // MARK: - Öffentliche API

    func get(_ path: String) async throws -> XMLNode {
        let (data, _) = try await send(path: path, body: nil, token: nil)
        return try Self.parseResponse(data)
    }

    /// Sendet `<request>inner</request>` per POST. Bei Token-Fehlern wird einmal neu versucht.
    func post(_ path: String, _ inner: String) async throws -> XMLNode {
        do {
            return try await postOnce(path, inner)
        } catch let error as RouterError where RouterError.tokenErrors.contains(error.code ?? "") {
            tokens.removeAll()
            return try await postOnce(path, inner)
        }
    }

    /// Rohzugriff für den API-Explorer. `body` ist das komplette XML (oder nil für GET).
    func raw(path: String, body: String?) async throws -> String {
        var token: String?
        if body != nil {
            if tokens.isEmpty { try await refreshToken() }
            token = nextToken()
        }
        let (data, _) = try await send(path: path, body: body, token: token)
        return String(decoding: data, as: UTF8.self)
    }

    func login(username: String, password: String) async throws {
        tokens.removeAll()
        sessionID = nil
        try await refreshToken()

        let firstNonce = Crypto.randomHex(bytes: 32)
        let challenge: XMLNode
        do {
            challenge = try await postOnce(
                "/api/user/challenge_login",
                "<username>\(username.xmlEscaped)</username><firstnonce>\(firstNonce)</firstnonce><mode>1</mode>"
            )
        } catch let error as RouterError where error.code == "100002" {
            // Ältere Firmware ohne SCRAM-Login
            try await legacyLogin(username: username, password: password)
            return
        }

        guard let salt = challenge["salt"],
              let iterations = challenge["iterations"].flatMap({ Int($0) }),
              let serverNonce = challenge["servernonce"] else {
            throw RouterError(code: nil, message: "Unerwartete Antwort beim Login")
        }

        let proof = Crypto.scramClientProof(
            password: password,
            saltHex: salt,
            iterations: iterations,
            firstNonce: firstNonce,
            serverNonce: serverNonce
        )
        _ = try await postOnce(
            "/api/user/authentication_login",
            "<clientproof>\(proof)</clientproof><finalnonce>\(serverNonce)</finalnonce>"
        )
    }

    func logout() async throws {
        _ = try await post("/api/user/logout", "<Logout>1</Logout>")
    }

    // MARK: - Intern

    private func legacyLogin(username: String, password: String) async throws {
        if tokens.isEmpty { try await refreshToken() }
        guard let token = tokens.first else {
            throw RouterError(code: nil, message: "Kein Token erhalten")
        }
        let passwordHash = Data(Crypto.sha256Hex(password).utf8).base64EncodedString()
        let auth = Data(Crypto.sha256Hex(username + passwordHash + token).utf8).base64EncodedString()
        _ = try await postOnce(
            "/api/user/login",
            "<Username>\(username.xmlEscaped)</Username><Password>\(auth)</Password><password_type>4</password_type>"
        )
    }

    private func postOnce(_ path: String, _ inner: String) async throws -> XMLNode {
        if tokens.isEmpty { try await refreshToken() }
        let body = #"<?xml version="1.0" encoding="UTF-8"?><request>"# + inner + "</request>"
        let (data, _) = try await send(path: path, body: body, token: nextToken())
        return try Self.parseResponse(data)
    }

    private func refreshToken() async throws {
        let (data, _) = try await send(path: "/api/webserver/SesTokInfo", body: nil, token: nil)
        let node = try Self.parseResponse(data)
        if sessionID == nil, let info = node["SesInfo"], let range = info.range(of: "SessionID=") {
            sessionID = String(info[range.upperBound...])
        }
        guard let token = node["TokInfo"], !token.isEmpty else {
            throw RouterError(code: nil, message: "Kein Token vom Router erhalten")
        }
        tokens = [token]
    }

    private func nextToken() -> String? {
        if tokens.count > 1 { return tokens.removeFirst() }
        return tokens.first
    }

    private func send(path: String, body: String?, token: String?) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw RouterError(code: nil, message: "Ungültiger Pfad")
        }
        var request = URLRequest(url: url)
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let sessionID {
            request.setValue("SessionID=\(sessionID)", forHTTPHeaderField: "Cookie")
        }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue(token, forHTTPHeaderField: "__RequestVerificationToken")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RouterError(code: nil, message: "Keine HTTP-Antwort")
        }
        capture(http)
        guard (200..<300).contains(http.statusCode) else {
            throw RouterError(code: nil, message: "HTTP \(http.statusCode)")
        }
        return (data, http)
    }

    /// Übernimmt neue Session-Cookies und Tokens aus den Antwort-Headern.
    private func capture(_ http: HTTPURLResponse) {
        if let cookie = http.value(forHTTPHeaderField: "Set-Cookie"),
           let range = cookie.range(of: "SessionID=") {
            sessionID = String(cookie[range.upperBound...].prefix { $0 != ";" })
        }
        if let one = http.value(forHTTPHeaderField: "__RequestVerificationTokenone") {
            tokens = [one]
            if let two = http.value(forHTTPHeaderField: "__RequestVerificationTokentwo") {
                tokens.append(two)
            }
        } else if let header = http.value(forHTTPHeaderField: "__RequestVerificationToken") {
            let parts = header.split(separator: "#").map(String.init).filter { !$0.isEmpty }
            if !parts.isEmpty { tokens = parts }
        }
    }

    private static func parseResponse(_ data: Data) throws -> XMLNode {
        guard let root = XMLNode.parse(data) else {
            throw RouterError(code: nil, message: "Antwort des Routers nicht lesbar")
        }
        if root.name == "error" {
            throw RouterError.fromCode(root["code"] ?? "?")
        }
        return root
    }
}
