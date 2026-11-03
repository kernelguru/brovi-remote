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

    /// Bekannte HiLink-Werte. Die 5G-Werte sind für den H153-381 noch nicht bestätigt.
    private struct ModePreset { let value: String; let label: String }
    private struct LTEBandInfo { let band: Int; let label: String }

    private static let modePresets: [ModePreset] = [
        ModePreset(value: "00", label: "Automatisch"),
        ModePreset(value: "03", label: "Nur 4G"),
        ModePreset(value: "08", label: "Nur 5G (ungeprüft)"),
        ModePreset(value: "0803", label: "5G + 4G (ungeprüft)"),
        ModePreset(value: "0302", label: "4G + 3G"),
        ModePreset(value: "02", label: "Nur 3G"),
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
                    Text("Rohwert aus /api/net/net-mode. Die 5G-Werte vor dem Speichern im API-Tab gegen „net-mode-list“ prüfen.")
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

    private func show(_ text: String, isError: Bool) {
        message = text
        self.isError = isError
    }
}
