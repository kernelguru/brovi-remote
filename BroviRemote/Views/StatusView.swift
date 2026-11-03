import SwiftUI

struct StatusView: View {
    let client: RouterClient
    @EnvironmentObject var model: AppModel
    @State private var signal: XMLNode?
    @State private var status: XMLNode?
    @State private var plmn: XMLNode?
    @State private var error: String?
    @State private var updated: Date?

    private static let lteKeys = ["mode", "band", "earfcn", "pci", "cell_id", "rsrp", "rsrq", "sinr", "rssi",
                                  "dlbandwidth", "ulbandwidth", "txpower"]

    private var lteFields: [Field] {
        Self.lteKeys.compactMap { key in
            guard let value = signal?[key], !value.isEmpty else { return nil }
            return Field(key: key, value: value)
        }
    }

    private var nrFields: [Field] {
        (signal?.fields ?? []).filter { $0.key.hasPrefix("nr") && !$0.value.isEmpty }
    }

    private var otherFields: [Field] {
        (signal?.fields ?? []).filter {
            !Self.lteKeys.contains($0.key) && !$0.key.hasPrefix("nr") && !$0.value.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section("Verbindung") {
                    info("Netzbetreiber", plmn?["FullName"])
                    info("Netztyp (Code)", status?["CurrentNetworkTypeEx"] ?? status?["CurrentNetworkType"])
                    info("Signalbalken", status?["SignalIcon"].map { "\($0) / 5" })
                    info("Verbindungsstatus (Code)", status?["ConnectionStatus"])
                }
                if !lteFields.isEmpty {
                    Section("4G / LTE") {
                        ForEach(lteFields) { SignalRow(field: $0) }
                    }
                }
                if !nrFields.isEmpty {
                    Section("5G / NR") {
                        ForEach(nrFields) { SignalRow(field: $0) }
                    }
                }
                if !otherFields.isEmpty {
                    Section("Weitere Werte") {
                        ForEach(otherFields) { SignalRow(field: $0) }
                    }
                }
                if let updated {
                    Section {
                        Text("Aktualisiert: \(updated.formatted(date: .omitted, time: .standard))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Funkstatus")
            .toolbar {
                Button("Abmelden") {
                    Task { await model.logout() }
                }
            }
            .refreshable { await load() }
            .task { await poll() }
        }
    }

    @ViewBuilder
    private func info(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title, value: value)
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func load() async {
        do {
            signal = try await client.get("/api/device/signal")
            status = try? await client.get("/api/monitoring/status")
            if plmn == nil {
                plmn = try? await client.get("/api/net/current-plmn")
            }
            updated = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SignalRow: View {
    let field: Field

    private static let labels: [String: String] = [
        "mode": "Modus",
        "band": "Band",
        "earfcn": "EARFCN",
        "pci": "PCI",
        "cell_id": "Zell-ID",
        "rsrp": "RSRP",
        "rsrq": "RSRQ",
        "sinr": "SINR",
        "rssi": "RSSI",
        "dlbandwidth": "DL-Bandbreite",
        "ulbandwidth": "UL-Bandbreite",
        "txpower": "Sendeleistung",
        "nrrsrp": "RSRP",
        "nrrsrq": "RSRQ",
        "nrsinr": "SINR",
        "nrearfcn": "NR-ARFCN",
        "nrdlbandwidth": "DL-Bandbreite",
        "nrulbandwidth": "UL-Bandbreite",
        "nrtxpower": "Sendeleistung",
    ]

    var body: some View {
        LabeledContent(Self.labels[field.key] ?? field.key) {
            Text(field.value)
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        let numeric = field.value.prefix { "-0123456789.".contains($0) }
        guard let value = Double(numeric) else { return .primary }
        switch field.key.replacingOccurrences(of: "nr", with: "") {
        case "rsrp": return value >= -85 ? .green : value >= -105 ? .orange : .red
        case "rsrq": return value >= -10 ? .green : value >= -15 ? .orange : .red
        case "sinr": return value >= 13 ? .green : value >= 0 ? .orange : .red
        default: return .primary
        }
    }
}
