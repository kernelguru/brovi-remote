import SwiftUI

/// Mobilfunk-Schalter, Datenverbrauch, LED, Neustart und Werkzeuge.
/// Formate laut den Seiten mobileconnection, statistic, systemsettings, volte und reboot der Weboberfläche.
struct DeviceView: View {
    let client: RouterClient

    @State private var dataSwitch: String?
    @State private var connection: XMLNode?
    @State private var volte: XMLNode?
    @State private var month: XMLNode?
    @State private var traffic: XMLNode?
    @State private var led: XMLNode?
    @State private var timeReboot: XMLNode?
    @State private var message: String?
    @State private var isError = false
    @State private var busy = false
    @State private var confirmReboot = false
    @State private var confirmClear = false

    @State private var ledStart = Date()
    @State private var ledEnd = Date()
    @State private var rebootTime = Date()
    @State private var rebootDays = 7

    var body: some View {
        NavigationStack {
            Form {
                if let message {
                    Section { Text(message).foregroundStyle(isError ? .red : .green) }
                }

                mobileSection
                trafficSection
                ledSection
                rebootSection

                Section("Werkzeuge") {
                    NavigationLink { OperatorView(client: client) } label: {
                        Label("Netzbetreiber", systemImage: "antenna.radiowaves.left.and.right.circle")
                    }
                    NavigationLink { ProfilesView(client: client) } label: {
                        Label("APN-Profile", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    NavigationLink { DiagnosisView(client: client) } label: {
                        Label("Ping & Traceroute", systemImage: "stethoscope")
                    }
                    NavigationLink { HostsView(client: client) } label: {
                        Label("Verbundene Geräte", systemImage: "laptopcomputer.and.iphone")
                    }
                    NavigationLink { ExplorerView(client: client) } label: {
                        Label("API-Explorer", systemImage: "terminal")
                    }
                }
            }
            .appBackground()
            .navigationTitle("Gerät")
            .refreshable { await load() }
            .task { await load() }
            .confirmationDialog("Router neu starten?", isPresented: $confirmReboot, titleVisibility: .visible) {
                Button("Neu starten", role: .destructive) { Task { await reboot() } }
            } message: {
                Text("Die Verbindung ist für etwa zwei Minuten unterbrochen.")
            }
            .confirmationDialog("Statistik zurücksetzen?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Zurücksetzen", role: .destructive) {
                    Task { await post("/api/monitoring/clear-traffic", "<ClearTraffic>1</ClearTraffic>", done: "Statistik zurückgesetzt.") }
                }
            }
        }
    }

    // MARK: - Abschnitte

    private var mobileSection: some View {
        Section {
            if let dataSwitch {
                Toggle("Mobile Daten", isOn: Binding(
                    get: { dataSwitch == "1" },
                    set: { on in
                        Task { await post("/api/dialup/mobile-dataswitch", "<dataswitch>\(on ? 1 : 0)</dataswitch>",
                                          done: on ? "Mobile Daten an." : "Mobile Daten aus.") }
                    }
                ))
            }
            if let connection {
                Toggle("Daten-Roaming", isOn: Binding(
                    get: { connection["RoamAutoConnectEnable"] == "1" },
                    set: { on in
                        Task { await repost("/api/dialup/connection", connection, key: "RoamAutoConnectEnable",
                                            value: on ? "1" : "0", done: on ? "Roaming an." : "Roaming aus.") }
                    }
                ))
            }
            if let volte {
                Toggle("VoLTE", isOn: Binding(
                    get: { volte["volte_enable"] == "1" },
                    set: { on in
                        Task { await repost("/api/voice/volte", volte, key: "volte_enable",
                                            value: on ? "1" : "0", done: on ? "VoLTE an." : "VoLTE aus.") }
                    }
                ))
            }
            Button("Netz neu verbinden") {
                Task {
                    await post("/api/net/reconnect", "<reconnect_action>1</reconnect_action>",
                               done: "Router verbindet sich neu.", timeout: 60)
                }
            }
        } header: {
            Text("Mobilfunk")
        }
        .disabled(busy)
    }

    private var trafficSection: some View {
        Section {
            if let month {
                stat("Dieser Monat ↓", bytes(month["CurrentMonthDownload"]))
                stat("Dieser Monat ↑", bytes(month["CurrentMonthUpload"]))
                stat("Heute", bytes(month["CurrentDayUsed"]))
                stat("Online diesen Monat", duration(month["MonthDuration"]))
            }
            if let traffic {
                stat("Sitzung ↓ / ↑", "\(bytes(traffic["CurrentDownload"])) / \(bytes(traffic["CurrentUpload"]))")
                stat("Aktuell ↓ / ↑", "\(rate(traffic["CurrentDownloadRate"])) / \(rate(traffic["CurrentUploadRate"]))")
                stat("Verbunden seit", duration(traffic["CurrentConnectTime"]))
            }
            Button("Statistik zurücksetzen", role: .destructive) { confirmClear = true }
                .disabled(busy)
        } header: {
            Text("Datenverbrauch")
        } footer: {
            if let since = month?["MonthLastClearTime"], !since.isEmpty {
                Text("Gezählt seit \(since).")
            }
        }
    }

    @ViewBuilder
    private var ledSection: some View {
        if let led {
            Section {
                Toggle("LED-Nachtmodus", isOn: Binding(
                    get: { led["ledctrlswitch"] == "1" },
                    set: { on in Task { await saveLED(on: on) } }
                ))
                if led["ledctrlswitch"] == "1" {
                    DatePicker("Aus ab", selection: $ledStart, displayedComponents: .hourAndMinute)
                    DatePicker("An ab", selection: $ledEnd, displayedComponents: .hourAndMinute)
                    Button("Zeiten speichern") { Task { await saveLED(on: true) } }
                }
            } header: {
                Text("LED")
            } footer: {
                Text("Schaltet die Anzeigen des Routers im gewählten Zeitraum ab.")
            }
            .disabled(busy)
        }
    }

    private var rebootSection: some View {
        Section {
            if let timeReboot {
                Toggle("Geplanter Neustart", isOn: Binding(
                    get: { timeReboot["enable"] == "1" },
                    set: { on in Task { await saveTimeReboot(on: on) } }
                ))
                if timeReboot["enable"] == "1" {
                    Stepper("Alle \(rebootDays) Tage", value: $rebootDays, in: 1...30)
                    DatePicker("Ab", selection: $rebootTime, displayedComponents: .hourAndMinute)
                    Button("Zeitplan speichern") { Task { await saveTimeReboot(on: true) } }
                }
            }
            Button("Router neu starten", role: .destructive) { confirmReboot = true }
        } header: {
            Text("Neustart")
        } footer: {
            if timeReboot?["enable"] == "1" {
                Text("Der Router startet im Zeitfenster ab der gewählten Uhrzeit neu, wenn das Netz nicht genutzt wird.")
            }
        }
        .disabled(busy)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).monospacedDigit() }
    }

    // MARK: - Laden & Speichern

    private func load() async {
        dataSwitch = (try? await client.get("/api/dialup/mobile-dataswitch"))?["dataswitch"]
        connection = try? await client.get("/api/dialup/connection")
        volte = try? await client.get("/api/voice/volte")
        month = try? await client.get("/api/monitoring/month_statistics")
        traffic = try? await client.get("/api/monitoring/traffic-statistics")
        led = try? await client.get("/api/led/appctrlled")
        timeReboot = try? await client.get("/api/diagnosis/time_reboot")
        if let led {
            ledStart = Self.date(fromClock: led["starttime"]) ?? ledStart
            ledEnd = Self.date(fromClock: led["endtime"]) ?? ledEnd
        }
        if let timeReboot {
            rebootTime = Self.date(fromMinutes: timeReboot["begintime"]) ?? rebootTime
            rebootDays = Int(timeReboot["dayinterval"] ?? "") ?? rebootDays
        }
    }

    private func post(_ path: String, _ inner: String, done: String, timeout: TimeInterval = RouterClient.defaultTimeout) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await client.post(path, inner, timeout: timeout)
            show(done, isError: false)
        } catch {
            show(error.localizedDescription, isError: true)
        }
        await load()
    }

    /// Schickt alle Felder der GET-Antwort zurück und ändert nur `key` (wie die Weboberfläche).
    private func repost(_ path: String, _ node: XMLNode, key: String, value: String, done: String) async {
        let inner = node.fields.map { field in
            "<\(field.key)>\((field.key == key ? value : field.value).xmlEscaped)</\(field.key)>"
        }.joined()
        await post(path, inner, done: done)
    }

    private func saveLED(on: Bool) async {
        let inner = "<ledctrlswitch>\(on ? 1 : 0)</ledctrlswitch>"
            + "<starttime>\(Self.clock(ledStart))</starttime><endtime>\(Self.clock(ledEnd))</endtime>"
        await post("/api/led/appctrlled", inner, done: on ? "LED-Nachtmodus gespeichert." : "LED-Nachtmodus aus.")
    }

    private func saveTimeReboot(on: Bool) async {
        let begin = Self.minutes(rebootTime)
        // Zeitfenster wie in der Router-Werkseinstellung (01:00–05:00): vier Stunden ab Beginn.
        let end = (begin + 240) % 1440
        let inner = "<enable>\(on ? 1 : 0)</enable><begintime>\(begin)</begintime>"
            + "<endtime>\(end)</endtime><dayinterval>\(rebootDays)</dayinterval>"
        await post("/api/diagnosis/time_reboot", inner, done: on ? "Zeitplan gespeichert." : "Geplanter Neustart aus.")
    }

    private func reboot() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await client.post("/api/device/control", "<Control>1</Control>")
            show("Router startet neu …", isError: false)
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    private func show(_ text: String, isError: Bool) {
        message = text
        self.isError = isError
    }

    // MARK: - Formatierung

    private func bytes(_ raw: String?) -> String {
        guard let raw, let value = Int64(raw) else { return "–" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Raten liefert der Router in Byte/s.
    private func rate(_ raw: String?) -> String {
        guard let raw, let value = Double(raw) else { return "–" }
        let bits = value * 8
        if bits >= 1_000_000 { return String(format: "%.1f Mbit/s", bits / 1_000_000) }
        return String(format: "%.0f kbit/s", bits / 1_000)
    }

    private func duration(_ raw: String?) -> String {
        guard let raw, let seconds = Int(raw) else { return "–" }
        let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
        return days > 0 ? "\(days) T \(hours) h" : "\(hours) h \(minutes) min"
    }

    private static func date(fromClock raw: String?) -> Date? {
        let parts = (raw ?? "").split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
    }

    private static func date(fromMinutes raw: String?) -> Date? {
        guard let raw, let minutes = Int(raw) else { return nil }
        return Calendar.current.date(bySettingHour: minutes / 60 % 24, minute: minutes % 60, second: 0, of: Date())
    }

    private static func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private static func minutes(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
