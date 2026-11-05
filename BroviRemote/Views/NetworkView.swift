import SwiftUI

/// Erweiterte Netz-Einstellungen über /api/net/net-mode.
/// Alle Felder, die der Router liefert, werden beim Speichern unverändert mitgeschickt,
/// nur die bearbeiteten Werte werden ersetzt.
struct NetworkView: View {
    let client: RouterClient

    @State private var loaded: [Field] = []
    @State private var networkMode = ""
    @State private var lteBandHex = ""
    @State private var extras: [Field] = []
    @State private var supported = ""
    @State private var message: String?
    @State private var isError = false
    @State private var busy = false
    @State private var confirmApply = false
    @State private var radioModeID = ""
    @State private var loadedRadioModeID = ""
    @State private var confirmRadioMode = false

    /// Werte laut /api/net/net-mode-list und config/network/net-mode.xml des H153-381.
    private struct ModePreset { let value: String; let label: String }
    private struct LTEBandInfo { let band: Int; let label: String }

    private static let modePresets: [ModePreset] = [
        ModePreset(value: "00", label: "Automatisch"),
        ModePreset(value: "08", label: "Nur 5G"),
        ModePreset(value: "03", label: "Nur 4G"),
    ]

    /// Funkmodus wie im (versteckten) Entwicklermenü „networkmode“ der Router-Weboberfläche:
    /// gesendet werden nur NetworkMode plus networkOption bzw. LTEBandOption.
    private struct RadioMode: Identifiable {
        let id: String
        let label: String
        let networkMode: String
        let field: String
        let value: String
    }

    private static let radioModes: [RadioMode] = [
        RadioMode(id: "sa", label: "5G SA", networkMode: "00", field: "networkOption", value: "1"),
        RadioMode(id: "nsa", label: "5G NSA", networkMode: "00", field: "networkOption", value: "0"),
        RadioMode(id: "sa_nsa", label: "5G SA + NSA", networkMode: "00", field: "networkOption", value: "2"),
        RadioMode(id: "lte", label: "Nur 4G", networkMode: "03", field: "LTEBandOption", value: "0"),
        RadioMode(id: "lte_tdd", label: "Nur 4G TDD", networkMode: "03", field: "LTEBandOption", value: "2"),
        RadioMode(id: "lte_fdd", label: "Nur 4G FDD", networkMode: "03", field: "LTEBandOption", value: "1"),
    ]

    private static let commonLTEBands: [LTEBandInfo] = [
        LTEBandInfo(band: 1, label: "2100 MHz"), LTEBandInfo(band: 3, label: "1800 MHz"),
        LTEBandInfo(band: 7, label: "2600 MHz"), LTEBandInfo(band: 8, label: "900 MHz"),
        LTEBandInfo(band: 20, label: "800 MHz"), LTEBandInfo(band: 28, label: "700 MHz"),
        LTEBandInfo(band: 32, label: "1500 MHz SDL"), LTEBandInfo(band: 38, label: "2600 MHz TDD"),
        LTEBandInfo(band: 40, label: "2300 MHz TDD"), LTEBandInfo(band: 41, label: "2500 MHz TDD"),
        LTEBandInfo(band: 42, label: "3500 MHz TDD"), LTEBandInfo(band: 43, label: "3700 MHz TDD"),
    ]

    private let mono = Font.system(.body, design: .monospaced)

    var body: some View {
        NavigationStack {
            Form {
                if let message {
                    Section {
                        Text(message).foregroundStyle(isError ? .red : .green)
                    }
                }

                Section {
                    Picker("Funkmodus", selection: $radioModeID) {
                        if radioModeID.isEmpty {
                            Text("Unbekannt").tag("")
                        }
                        ForEach(Self.radioModes) { mode in
                            Text(mode.label).tag(mode.id)
                        }
                    }
                    Button("Funkmodus übernehmen") { confirmRadioMode = true }
                        .disabled(busy || radioModeID.isEmpty || radioModeID == loadedRadioModeID)
                        .confirmationDialog("Funkmodus ändern?", isPresented: $confirmRadioMode, titleVisibility: .visible) {
                            Button("Übernehmen") { Task { await applyRadioMode() } }
                        } message: {
                            Text(radioModeID == "sa"
                                 ? "Im reinen SA-Modus bricht die Verbindung ab, wenn am Standort kein 5G SA verfügbar ist. Der Router verbindet sich neu, das kann bis zu einer Minute dauern."
                                 : "Der Router verbindet sich neu, das kann bis zu einer Minute dauern.")
                        }
                } header: {
                    Text("5G-Modus")
                } footer: {
                    Text("SA = Standalone, NSA = Non-Standalone (5G mit 4G-Anker).")
                }

                Section {
                    LabeledContent("NetworkMode") {
                        TextField("00", text: $networkMode)
                            .font(mono)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                    }
                    Menu("Vorlage wählen") {
                        ForEach(Self.modePresets, id: \.value) { preset in
                            Button("\(preset.label) (\(preset.value))") { networkMode = preset.value }
                        }
                    }
                } header: {
                    Text("Netzmodus")
                } footer: {
                    Text("Rohwert aus /api/net/net-mode. Für SA/NSA den Abschnitt „5G-Modus“ verwenden.")
                }

                Section {
                    LabeledContent("LTEBand (Hex)") {
                        TextField("7FFFFFFFFFFFFFFF", text: $lteBandHex)
                            .font(mono)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters)
                    }
                    Button("Alle Bänder freigeben") { lteBandHex = BandMask.allBands }
                    ForEach(Self.commonLTEBands, id: \.band) { item in
                        Toggle("B\(item.band) · \(item.label)", isOn: bandBinding(item.band))
                    }
                } header: {
                    Text("LTE-Bänder")
                }

                if !extras.isEmpty {
                    Section {
                        ForEach($extras) { $field in
                            LabeledContent(field.key) {
                                TextField("", text: $field.value)
                                    .font(mono)
                                    .multilineTextAlignment(.trailing)
                                    .textInputAutocapitalization(.never)
                            }
                        }
                    } header: {
                        Text("Weitere Felder vom Router")
                    } footer: {
                        Text("z. B. NetworkBand (2G/3G) oder 5G-Bandmasken, je nach Firmware.")
                    }
                }

                Section {
                    Button("Übernehmen") { confirmApply = true }
                        .disabled(busy || loaded.isEmpty)
                    Button("Neu laden") { Task { await load() } }
                        .disabled(busy)
                }

                if !supported.isEmpty {
                    Section("Vom Router unterstützt (net-mode-list)") {
                        Text(supported)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .appBackground()
            .navigationTitle("Netz")
            .confirmationDialog("Einstellungen übernehmen?", isPresented: $confirmApply, titleVisibility: .visible) {
                Button("Übernehmen") { Task { await apply() } }
            } message: {
                Text("Der Router baut die Mobilfunkverbindung dabei kurz neu auf.")
            }
            .task { await load() }
        }
    }

    private func bandBinding(_ band: Int) -> Binding<Bool> {
        Binding(
            get: { BandMask.bands(fromHex: lteBandHex).contains(band) },
            set: { enabled in
                var bands = BandMask.bands(fromHex: lteBandHex)
                if enabled { bands.insert(band) } else { bands.remove(band) }
                lteBandHex = BandMask.hex(from: bands)
            }
        )
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do {
            let node = try await client.get("/api/net/net-mode")
            loaded = node.fields
            networkMode = node["NetworkMode"] ?? ""
            lteBandHex = node["LTEBand"] ?? ""
            extras = loaded.filter { $0.key != "NetworkMode" && $0.key != "LTEBand" }
            loadedRadioModeID = Self.radioModeID(for: node)
            radioModeID = loadedRadioModeID
            supported = (try? await client.raw(path: "/api/net/net-mode-list", body: nil)) ?? ""
            message = nil
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    private func apply() async {
        if BandMask.bands(fromHex: lteBandHex).isEmpty {
            show("Mindestens ein LTE-Band muss aktiv sein.", isError: true)
            return
        }
        busy = true
        defer { busy = false }
        var inner = ""
        for field in loaded {
            let value: String
            switch field.key {
            case "NetworkMode": value = networkMode
            case "LTEBand": value = lteBandHex
            default: value = extras.first { $0.key == field.key }?.value ?? field.value
            }
            inner += "<\(field.key)>\(value.xmlEscaped)</\(field.key)>"
        }
        do {
            _ = try await client.post("/api/net/net-mode", inner)
            show("Gespeichert.", isError: false)
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    /// Entspricht getConversionValue im Router-Skript networkmode.js.
    private static func radioModeID(for node: XMLNode) -> String {
        guard let networkMode = node["NetworkMode"] else { return "" }
        return radioModes.first { mode in
            mode.networkMode == networkMode && node[mode.field] == mode.value
        }?.id ?? ""
    }

    private func applyRadioMode() async {
        guard let mode = Self.radioModes.first(where: { $0.id == radioModeID }) else { return }
        busy = true
        show("Router verbindet sich neu …", isError: false)
        let inner = "<NetworkMode>\(mode.networkMode)</NetworkMode><\(mode.field)>\(mode.value)</\(mode.field)>"
        do {
            _ = try await client.post("/api/net/net-mode", inner, timeout: 90)
            busy = false
            await load()
            show("Funkmodus „\(mode.label)“ gesetzt.", isError: false)
        } catch {
            busy = false
            show(error.localizedDescription, isError: true)
        }
    }

    private func show(_ text: String, isError: Bool) {
        message = text
        self.isError = isError
    }
}
