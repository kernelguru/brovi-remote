import SwiftUI

// MARK: - Gemeinsame Statusanzeige

private struct StatusMessage: View {
    let text: String?
    let isError: Bool

    var body: some View {
        if let text {
            Section { Text(text).foregroundStyle(isError ? .red : .green) }
        }
    }
}

// MARK: - Netzbetreiber

/// Netzsuche und manuelle Betreiberwahl (Seite „mobilesearch“: /api/net/plmn-list, /api/net/register).
struct OperatorView: View {
    let client: RouterClient

    private struct Network: Identifiable {
        let id: String
        let name: String
        let numeric: String
        let rat: String
        let state: String
    }

    @State private var register: XMLNode?
    @State private var current: XMLNode?
    @State private var networks: [Network] = []
    @State private var searching = false
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        Form {
            StatusMessage(text: message, isError: isError)

            Section("Aktuell") {
                LabeledContent("Betreiber", value: current?["FullName"] ?? current?["ShortName"] ?? "–")
                LabeledContent("Auswahl", value: register?["Mode"] == "1" ? "Manuell" : "Automatisch")
                if register?["Mode"] == "1" {
                    Button("Wieder automatisch wählen") {
                        Task { await choose("<Mode>0</Mode><Plmn></Plmn><Rat></Rat>", done: "Automatische Netzwahl aktiv.") }
                    }
                    .disabled(busy)
                }
            }

            Section {
                Button {
                    Task { await search() }
                } label: {
                    HStack {
                        Text(searching ? "Suche läuft …" : "Netze suchen")
                        if searching { Spacer(); ProgressView() }
                    }
                }
                .disabled(searching || busy)
                ForEach(networks) { network in
                    Button {
                        Task {
                            await choose("<Mode>1</Mode><Plmn>\(network.numeric.xmlEscaped)</Plmn><Rat>\(network.rat.xmlEscaped)</Rat>",
                                         done: "Eingebucht bei \(network.name).")
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(network.name).foregroundStyle(.primary)
                                Text("\(network.numeric) · \(Self.ratName(network.rat))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Self.stateName(network.state))
                                .font(.caption)
                                .foregroundStyle(network.state == "3" ? .red : network.state == "2" ? .green : .secondary)
                        }
                    }
                    .disabled(busy || network.state == "3")
                }
            } header: {
                Text("Verfügbare Netze")
            } footer: {
                Text("Die Suche trennt die Verbindung und kann bis zu vier Minuten dauern. Eine manuelle Wahl bleibt bestehen, bis wieder „automatisch“ gewählt wird.")
            }
        }
        .appBackground()
        .navigationTitle("Netzbetreiber")
        .task { await load() }
    }

    private func load() async {
        register = try? await client.get("/api/net/register")
        current = try? await client.get("/api/net/current-plmn")
    }

    private func search() async {
        searching = true
        defer { searching = false }
        do {
            let node = try await client.get("/api/net/plmn-list", timeout: 240)
            networks = (node.child("Networks")?.children(named: "Network") ?? []).enumerated().map { index, item in
                Network(id: "\(index)-\(item["Numeric"] ?? "")-\(item["Rat"] ?? "")",
                        name: item["FullName"].flatMap { $0.isEmpty ? nil : $0 } ?? item["ShortName"] ?? item["Numeric"] ?? "?",
                        numeric: item["Numeric"] ?? "",
                        rat: item["Rat"] ?? "",
                        state: item["State"] ?? "")
            }
            message = networks.isEmpty ? "Keine Netze gefunden." : nil
            isError = networks.isEmpty
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }

    private func choose(_ inner: String, done: String) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await client.post("/api/net/register", inner, timeout: 90)
            message = done
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
        await load()
    }

    private static func ratName(_ rat: String) -> String {
        ["0": "2G", "2": "3G", "7": "4G", "11": "5G", "12": "5G"][rat] ?? "RAT \(rat)"
    }

    private static func stateName(_ state: String) -> String {
        ["1": "verfügbar", "2": "aktuell", "3": "gesperrt"][state] ?? ""
    }
}

// MARK: - APN-Profile

/// APN-Profile aus /api/dialup/profiles (Passwörter werden nicht angezeigt).
struct ProfilesView: View {
    let client: RouterClient

    private struct Profile: Identifiable {
        let id: String
        let name: String
        let apn: String
        let ipType: String
        let readOnly: Bool
    }

    @State private var profiles: [Profile] = []
    @State private var currentID = ""
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        Form {
            StatusMessage(text: message, isError: isError)
            Section {
                ForEach(profiles) { profile in
                    Button {
                        Task { await setDefault(profile) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(profile.name).foregroundStyle(.primary)
                                Text("APN \(profile.apn.isEmpty ? "–" : profile.apn)\(profile.ipType.isEmpty ? "" : " · \(Self.ipName(profile.ipType))")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if profile.id == currentID {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.cyan)
                            }
                        }
                    }
                    .disabled(busy || profile.id == currentID)
                }
            } header: {
                Text("Profile")
            } footer: {
                Text("Antippen macht ein Profil zum Standard. Der Router verbindet sich dabei neu.")
            }
        }
        .appBackground()
        .navigationTitle("APN-Profile")
        .task { await load() }
    }

    private func load() async {
        do {
            let node = try await client.get("/api/dialup/profiles")
            currentID = node["CurrentProfile"] ?? ""
            profiles = (node.child("Profiles")?.children(named: "Profile") ?? []).map { item in
                Profile(id: item["Index"] ?? UUID().uuidString,
                        name: item["Name"] ?? "Profil",
                        apn: item["ApnName"] ?? "",
                        ipType: item["iptype"] ?? "",
                        readOnly: item["ReadOnly"] == "1")
            }
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }

    private func setDefault(_ profile: Profile) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await client.post("/api/dialup/profiles",
                                      "<Delete>0</Delete><SetDefault>\(profile.id.xmlEscaped)</SetDefault><Modify>0</Modify>",
                                      timeout: 60)
            message = "„\(profile.name)“ ist jetzt Standard."
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
        await load()
    }

    private static func ipName(_ type: String) -> String {
        ["0": "IPv4", "1": "IPv6", "2": "IPv4v6"][type] ?? type
    }
}

// MARK: - Ping & Traceroute

/// Diagnose wie die Seite „diagnosis“: POST startet, GET liefert das Ergebnis.
struct DiagnosisView: View {
    let client: RouterClient

    @State private var traceroute = false
    @State private var host = "8.8.8.8"
    @State private var timeoutSeconds = 5
    @State private var maxHops = 30
    @State private var services: [String] = ["INTERNET"]
    @State private var service = "INTERNET"
    @State private var running = false
    @State private var result: [Field] = []
    @State private var reply = ""
    @State private var message: String?

    var body: some View {
        Form {
            if let message {
                Section { Text(message).foregroundStyle(.red) }
            }
            Section {
                Picker("Test", selection: $traceroute) {
                    Text("Ping").tag(false)
                    Text("Traceroute").tag(true)
                }
                .pickerStyle(.segmented)
                TextField("Ziel (IP oder Name)", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Stepper("Zeitlimit \(timeoutSeconds) s", value: $timeoutSeconds, in: traceroute ? 2...10 : 1...60)
                if traceroute {
                    Stepper("Max. Hops \(maxHops)", value: $maxHops, in: 1...64)
                }
                if services.count > 1 {
                    Picker("Verbindung", selection: $service) {
                        ForEach(services, id: \.self) { Text($0).tag($0) }
                    }
                }
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        Text(running ? "Läuft …" : "Starten")
                        if running { Spacer(); ProgressView() }
                    }
                }
                .disabled(running || host.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !reply.isEmpty {
                Section("Ausgabe") {
                    Text(reply)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if !result.isEmpty {
                Section("Ergebnis") {
                    ForEach(result) { field in
                        LabeledContent(field.key, value: field.value)
                    }
                }
            }
        }
        .appBackground()
        .navigationTitle("Ping & Traceroute")
        .task { await loadServices() }
        .onChange(of: traceroute) { isTrace in
            timeoutSeconds = min(timeoutSeconds, isTrace ? 10 : 60)
            if isTrace { timeoutSeconds = max(timeoutSeconds, 2) }
        }
    }

    private func loadServices() async {
        guard let raw = (try? await client.get("/api/diagnosis/get-wan-service-name"))?["service_name"] else { return }
        let names = raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        let filtered = names.filter { $0 != "INTERNET" }
        if !filtered.isEmpty {
            services = filtered
            service = filtered[0]
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        message = nil
        result = []
        reply = ""
        let path = traceroute ? "/api/diagnosis/diagnose_traceroute" : "/api/diagnosis/diagnose_ping"
        var inner = "<ServiceName>\(service.xmlEscaped)</ServiceName><Host>\(host.trimmingCharacters(in: .whitespaces).xmlEscaped)</Host>"
        if traceroute { inner += "<MaxHopCount>\(maxHops)</MaxHopCount>" }
        inner += "<Timeout>\(timeoutSeconds * 1000)</Timeout>"
        do {
            _ = try await client.post(path, inner, timeout: 45)
            for _ in 0..<60 {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                let node = try await client.get(path)
                if node["DiagnosticsState"] == "Requested" { continue }
                reply = Self.plainText(node["Reply"] ?? node["RouteHops"] ?? "")
                result = node.fields.filter { !$0.value.isEmpty && $0.key != "Reply" }
                return
            }
            message = "Keine Antwort vom Router."
        } catch {
            message = error.localizedDescription
        }
    }

    /// Die Antwort enthält teils HTML-Zeilen (<div>…</div>).
    private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "</div>", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Verbundene Geräte

/// Geräteliste aus /api/system/HostInfo (die Weboberfläche bekommt hier JSON).
struct HostsView: View {
    let client: RouterClient

    private struct Host: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let fields: [Field]
    }

    @State private var hosts: [Host] = []
    @State private var raw = ""
    @State private var message: String?

    var body: some View {
        Form {
            if let message {
                Section { Text(message).foregroundStyle(.red) }
            }
            if hosts.isEmpty && !raw.isEmpty {
                Section("Antwort") {
                    Text(raw).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                }
            }
            Section("\(hosts.count) Geräte") {
                ForEach(hosts) { host in
                    DisclosureGroup {
                        ForEach(host.fields) { field in
                            LabeledContent(field.key, value: field.value).font(.caption)
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(host.title)
                            Text(host.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .appBackground()
        .navigationTitle("Verbundene Geräte")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            let text = try await client.raw(path: "/api/system/HostInfo", body: nil)
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: text.unicodeScalars.filter { $0.value >= 0x20 })
            let cleaned = String(scalars)
            if let json = try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)) {
                hosts = Self.entries(in: json).enumerated().map { index, entry in
                    let fields = entry.keys.sorted().map { Field(key: $0, value: "\(entry[$0] ?? "")") }
                    func value(_ keys: [String]) -> String? {
                        keys.lazy.compactMap { key in entry[key].map { "\($0)" } }.first { !$0.isEmpty }
                    }
                    let title = value(["ActualName", "HostName", "hostname", "Name", "name", "DeviceName"]) ?? "Gerät \(index + 1)"
                    let ip = value(["IpAddress", "IPAddress", "ip", "Ip"]) ?? ""
                    let mac = value(["MacAddress", "MACAddress", "mac", "Mac"]) ?? ""
                    return Host(id: "\(index)-\(mac)", title: title,
                                subtitle: [ip, mac].filter { !$0.isEmpty }.joined(separator: " · "), fields: fields)
                }
                raw = ""
            } else {
                hosts = []
                raw = text
            }
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    /// Sucht die erste Liste von Objekten in beliebig verschachteltem JSON.
    private static func entries(in json: Any) -> [[String: Any]] {
        if let list = json as? [[String: Any]] { return list }
        if let dict = json as? [String: Any] {
            for value in dict.values {
                let found = entries(in: value)
                if !found.isEmpty { return found }
            }
        }
        if let list = json as? [Any] {
            for value in list {
                let found = entries(in: value)
                if !found.isEmpty { return found }
            }
        }
        return []
    }
}
