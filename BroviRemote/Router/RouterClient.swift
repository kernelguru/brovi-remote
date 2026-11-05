import Foundation

struct RouterError: LocalizedError {
    let code: String?
    let message: String

    var errorDescription: String? {
        if let code { return "\(message) (Code \(code))" }
        return message
    }

    static let tokenErrors: Set<String> = ["125001", "125002", "125003"]
    /// Fehler, nach denen eine Neuanmeldung sinnvoll ist (Sitzung abgelaufen).
    static let sessionErrors: Set<String> = ["100003", "125002"]

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
        // Obergrenze; die eigentliche Zeitüberschreitung setzt jede Anfrage selbst.
        config.timeoutIntervalForRequest = 120
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    /// Zugangsdaten nur im Arbeitsspeicher, um abgelaufene Sitzungen still zu erneuern.
    private var credentials: (username: String, password: String)?

    // MARK: - Öffentliche API

    func get(_ path: String, timeout: TimeInterval = RouterClient.defaultTimeout) async throws -> XMLNode {
        try await recoveringSession { try await self.getOnce(path, timeout: timeout) }
    }

    /// Sendet `<request>inner</request>` per POST.
    /// `timeout`: z. B. 90 s für Funkmodus-Wechsel, bei denen der Router die Verbindung neu aufbaut.
    func post(_ path: String, _ inner: String, timeout: TimeInterval = RouterClient.defaultTimeout) async throws -> XMLNode {
        try await recoveringSession { try await self.postRetryingToken(path, inner, timeout: timeout) }
    }

    /// Rohzugriff für den API-Explorer. `body` ist das komplette XML (oder nil für GET).
    func raw(path: String, body: String?) async throws -> String {
        try await recoveringSession { try await self.rawOnce(path: path, body: body) }
    }

    func login(username: String, password: String) async throws {
        try await performLogin(username: username, password: password)
        credentials = (username, password)
    }

    /// Arten verschlüsselter Anfragen (Parameter `enc-type` der Weboberfläche).
    enum Encryption: String {
        /// Anfrage und Antwort im Klartext, nur Client-Schlüssel in der URL (z. B. SMS senden).
        case keyOnly = "2"
        /// Antwort verschlüsselt (z. B. Listen mit persönlichen Daten).
        case response = "3"
        /// Anfrage und Antwort verschlüsselt.
        case full = "1"
    }

    /// POST wie die Weboberfläche mit Content-Type „…;enc“ (Curve25519 + AES-GCM, siehe EccSession).
    func postEncrypted(_ path: String, _ inner: String, encryption: Encryption,
                       timeout: TimeInterval = RouterClient.defaultTimeout) async throws -> XMLNode {
        try await recoveringSession {
            do {
                return try await self.postEncryptedOnce(path, inner, encryption: encryption, timeout: timeout)
            } catch let error as RouterError where RouterError.tokenErrors.contains(error.code ?? "") {
                self.tokens.removeAll()
                return try await self.postEncryptedOnce(path, inner, encryption: encryption, timeout: timeout)
            }
        }
    }

    /// Zweite Anmeldung (loginflag 2) wie im Entwicklermenü der Weboberfläche.
    /// Erst danach liefern z. B. /api/net/lock-freq und /api/net/lte-band-info Daten.
    func enableDeveloperAccess() async throws {
        try await recoveringSession { try await self.developerLoginIfNeeded() }
        developerAccess = true
    }

    func logout() async throws {
        credentials = nil
        developerAccess = false
        ecc = nil
        _ = try await postRetryingToken("/api/user/logout", "<Logout>1</Logout>")
    }

    // MARK: - Sitzung

    /// Läuft die Router-Sitzung ab (z. B. nach längerer Pause), wird einmal neu angemeldet.
    private func recoveringSession<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as RouterError where RouterError.sessionErrors.contains(error.code ?? "") {
            guard let credentials else { throw error }
            try await performLogin(username: credentials.username, password: credentials.password)
            if developerAccess { try? await developerLoginIfNeeded() }
            return try await operation()
        }
    }

    private var developerAccess = false
    private var ecc: EccSession?

    private func developerLoginIfNeeded() async throws {
        if let state = try? await getOnce("/api/user/second_login"), state["enable"] == "1" { return }
        guard let credentials else {
            throw RouterError(code: nil, message: "Keine Zugangsdaten für die Entwickleranmeldung")
        }
        guard try await scramLogin(username: credentials.username, password: credentials.password, loginFlag: "2") else {
            throw RouterError(code: nil, message: "Entwickleranmeldung wird nicht unterstützt")
        }
    }

    private func eccSession() async throws -> EccSession {
        if let ecc { return ecc }
        let node = try await getOnce("/api/webserver/publickey")
        guard let serverKey = node["ecc_server_pubkey"], !serverKey.isEmpty else {
            throw RouterError(code: nil, message: "Router bietet keine ECC-Verschlüsselung an (nur RSA – noch nicht unterstützt)")
        }
        let session = try EccSession(serverKeyHex: serverKey)
        ecc = session
        return session
    }

    private func postEncryptedOnce(_ path: String, _ inner: String, encryption: Encryption,
                                   timeout: TimeInterval) async throws -> XMLNode {
        let session = try await eccSession()
        if tokens.isEmpty { try await refreshToken() }
        var body = #"<?xml version="1.0" encoding="UTF-8"?><request>"# + inner + "</request>"
        if encryption == .full { body = try session.encrypt(body) }
        let url = "\(path)?ecc-client-pubkey=\(session.clientKeyHex)&enc-type=\(encryption.rawValue)"
        let (data, _) = try await send(path: url, body: body, token: nextToken(), timeout: timeout,
                                       contentType: "application/x-www-form-urlencoded; charset=UTF-8")
        // Klartext-XML direkt auswerten, sonst als verschlüsselten Hex-Block entschlüsseln.
        if let node = XMLNode.parse(data) {
            if node.name == "error" { throw RouterError.fromCode(node["code"] ?? "?") }
            if node.children.isEmpty, node.value.count > 64, node.value.allSatisfy(\.isHexDigit) {
                return try Self.decryptedNode(node.value, session: session)
            }
            return node
        }
        return try Self.decryptedNode(String(decoding: data, as: UTF8.self), session: session)
    }

    private static func decryptedNode(_ hex: String, session: EccSession) throws -> XMLNode {
        let plain = try session.decrypt(hex)
        let xml = plain.range(of: "<response>").map { String(plain[$0.lowerBound...]) } ?? plain
        return try parseResponse(Data(xml.utf8))
    }

    private func getOnce(_ path: String, timeout: TimeInterval = RouterClient.defaultTimeout) async throws -> XMLNode {
        let (data, _) = try await send(path: path, body: nil, token: tokens.count == 1 ? tokens[0] : nil, timeout: timeout)
        return try Self.parseResponse(data)
    }

    /// Bei Token-Fehlern wird einmal mit frischem Token neu versucht.
    private func postRetryingToken(_ path: String, _ inner: String,
                                   timeout: TimeInterval = RouterClient.defaultTimeout) async throws -> XMLNode {
        do {
            return try await postOnce(path, inner, timeout: timeout)
        } catch let error as RouterError where RouterError.tokenErrors.contains(error.code ?? "") {
            tokens.removeAll()
            return try await postOnce(path, inner, timeout: timeout)
        }
    }

    private func rawOnce(path: String, body: String?) async throws -> String {
        var token: String? = tokens.count == 1 ? tokens[0] : nil
        if body != nil {
            if tokens.isEmpty { try await refreshToken() }
            token = nextToken()
        }
        let (data, _) = try await send(path: path, body: body, token: token)
        if let node = XMLNode.parse(data), node.name == "error",
           let code = node["code"], RouterError.sessionErrors.contains(code) {
            throw RouterError.fromCode(code)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Login wie in huawei-lte-api (Salamek): state-login prüfen, bei password_type 4
    /// zuerst SCRAM versuchen, sonst bzw. als Rückfall den klassischen Login.
    private func performLogin(username: String, password: String) async throws {
        tokens.removeAll()
        sessionID = nil
        try await initializeSession()

        let state: XMLNode
        do {
            state = try await getOnce("/api/user/state-login")
        } catch let error as RouterError where error.code == "100002" {
            return // Gerät ohne Login
        }
        if state["State"] == "0" { return } // bereits angemeldet

        let passwordType = state["password_type"] ?? "0"
        if passwordType == "4" {
            if try await scramLogin(username: username, password: password) { return }
            if tokens.isEmpty { try await initializeSession() }
        }
        try await legacyLogin(username: username, password: password, passwordType: passwordType)
    }

    // MARK: - Intern

    /// Gibt `false` zurück, wenn der Router kein SCRAM anbietet (dann klassischer Login).
    private func scramLogin(username: String, password: String, loginFlag: String? = nil) async throws -> Bool {
        let firstNonce = Crypto.randomHex(bytes: 32)
        let challenge: XMLNode
        var inner = "<username>\(username.xmlEscaped)</username><firstnonce>\(firstNonce)</firstnonce><mode>1</mode>"
        if let loginFlag { inner += "<loginflag>\(loginFlag)</loginflag>" }
        do {
            challenge = try await postOnce("/api/user/challenge_login", inner)
        } catch let error as RouterError where error.code == "100002" || error.code == "100003" {
            return false
        }

        guard let salt = challenge["salt"],
              let iterations = challenge["iterations"].flatMap({ Int($0) }),
              let serverNonce = challenge["servernonce"] else {
            return false
        }

        let scram = Crypto.scram(
            password: password,
            saltHex: salt,
            iterations: iterations,
            firstNonce: firstNonce,
            serverNonce: serverNonce
        )
        let result = try await postOnce(
            "/api/user/authentication_login",
            "<clientproof>\(scram.clientProof)</clientproof><finalnonce>\(serverNonce)</finalnonce>"
        )
        guard result["serversignature"]?.lowercased() == scram.serverSignature else {
            throw RouterError(code: nil, message: "Ungültige Server-Signatur beim Login")
        }
        return true
    }

    private func legacyLogin(username: String, password: String, passwordType: String) async throws {
        if tokens.isEmpty { try await initializeSession() }
        let encoded: String
        if passwordType == "4" {
            guard let token = tokens.first else {
                throw RouterError(code: nil, message: "Kein Token erhalten")
            }
            let passwordHash = Data(Crypto.sha256Hex(password).utf8).base64EncodedString()
            encoded = Data(Crypto.sha256Hex(username + passwordHash + token).utf8).base64EncodedString()
        } else {
            encoded = Data(password.utf8).base64EncodedString()
        }
        _ = try await postOnce(
            "/api/user/login",
            "<Username>\(username.xmlEscaped)</Username><Password>\(encoded)</Password><password_type>\(passwordType)</password_type>"
        )
    }

    private func postOnce(_ path: String, _ inner: String,
                          timeout: TimeInterval = RouterClient.defaultTimeout) async throws -> XMLNode {
        if tokens.isEmpty { try await refreshToken() }
        let body = #"<?xml version="1.0" encoding="UTF-8"?><request>"# + inner + "</request>"
        let (data, _) = try await send(path: path, body: body, token: nextToken(), timeout: timeout)
        return try Self.parseResponse(data)
    }

    /// Startseite laden (Session-Cookie + csrf_token aus den Meta-Tags), sonst Token per API holen.
    private func initializeSession() async throws {
        if let result = try? await send(path: "/", body: nil, token: nil) {
            let html = String(decoding: result.0, as: UTF8.self)
            let found = Self.csrfTokens(in: html)
            if !found.isEmpty, sessionID != nil {
                tokens = found
                return
            }
        }
        try await refreshToken()
    }

    private func refreshToken() async throws {
        if let node = try? await getOnce("/api/webserver/token"), let token = node["token"], !token.isEmpty {
            tokens = [token]
            return
        }
        let node = try await getOnce("/api/webserver/SesTokInfo")
        if sessionID == nil, let info = node["SesInfo"], let range = info.range(of: "SessionID=") {
            sessionID = String(info[range.upperBound...])
        }
        guard let token = node["TokInfo"], !token.isEmpty else {
            throw RouterError(code: nil, message: "Kein Token vom Router erhalten")
        }
        tokens = [token]
    }

    private static func csrfTokens(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"name="csrf_token"\s+content="(\S+)""#) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            Range(match.range(at: 1), in: html).map { String(html[$0]) }
        }
    }

    private func nextToken() -> String? {
        if tokens.count > 1 { return tokens.removeFirst() }
        return tokens.first
    }

    static let defaultTimeout: TimeInterval = 10

    private func send(path: String, body: String?, token: String?,
                      timeout: TimeInterval = RouterClient.defaultTimeout,
                      contentType: String = "application/xml") async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw RouterError(code: nil, message: "Ungültiger Pfad")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let sessionID {
            request.setValue("SessionID=\(sessionID)", forHTTPHeaderField: "Cookie")
        }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
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
