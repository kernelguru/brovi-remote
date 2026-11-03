import SwiftUI

struct StatusView: View {
    let client: RouterClient
    @EnvironmentObject var model: AppModel
    @State private var signal: XMLNode?
    @State private var status: XMLNode?
    @State private var plmn: XMLNode?
    @State private var error: String?
    @State private var updated: Date?

    private static let lteMetrics = ["rsrp", "rsrq", "sinr"]
    private static let lteDetails = ["band", "earfcn", "pci", "cell_id", "rssi", "dlbandwidth", "ulbandwidth", "txpower", "mode"]
    private static let nrMetrics = ["nrrsrp", "nrrsrq", "nrsinr"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard()
                    }
                    connectionCard
                    if hasNR { nrCard }
                    if hasLTE { lteCard }
                    if !otherFields.isEmpty { otherCard }
                    if let updated {
                        Text("Aktualisiert \(updated.formatted(date: .omitted, time: .standard))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .background(AppBackground())
            .navigationTitle("Funkstatus")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Abmelden", systemImage: "rectangle.portrait.and.arrow.right") {
                            Task { await model.logout() }
                        }
                        if model.hasSavedLogin {
                            Button("Gespeicherte Anmeldung löschen", systemImage: "trash", role: .destructive) {
                                model.forgetSavedLogin()
                            }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .refreshable { await load() }
            .task { await poll() }
        }
    }

    // MARK: - Karten

    private var connectionCard: some View {
        GlassCard(title: "Verbindung", systemImage: "dot.radiowaves.up.forward") {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plmn?["FullName"] ?? plmn?["ShortName"] ?? "–")
                        .font(.title2.bold())
                    Text(networkTypeName)
                        .font(.subheadline)
                        .foregroundStyle(Theme.cyan)
                }
                Spacer()
                Image(systemName: "cellularbars", variableValue: signalBars)
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
            }
        }
    }

    private var nrCard: some View {
        GlassCard(title: "5G NR", systemImage: "5.circle") {
            metricGrid(Self.nrMetrics)
            details(nrDetailFields)
        }
    }

    private var lteCard: some View {
        GlassCard(title: "4G LTE", systemImage: "4.circle") {
            metricGrid(Self.lteMetrics)
            details(Self.lteDetails.compactMap(field))
        }
    }

    private var otherCard: some View {
        GlassCard(title: "Weitere Werte", systemImage: "list.bullet") {
            DisclosureGroup("\(otherFields.count) Werte anzeigen") {
                details(otherFields)
                    .padding(.top, 8)
            }
        }
    }

    private func metricGrid(_ keys: [String]) -> some View {
        let fields = keys.compactMap(field)
        return HStack(spacing: 10) {
            ForEach(fields) { MetricTile(field: $0) }
        }
    }

    private func details(_ fields: [Field]) -> some View {
        VStack(spacing: 8) {
            ForEach(fields) { item in
                HStack {
                    Text(SignalFormat.label(item.key))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(item.value)
                        .monospacedDigit()
                }
                .font(.subheadline)
            }
        }
    }

    // MARK: - Daten

    private func field(_ key: String) -> Field? {
        guard let value = signal?[key], !value.isEmpty else { return nil }
        return Field(key: key, value: value)
    }

    private var hasNR: Bool { Self.nrMetrics.contains { field($0) != nil } }
    private var hasLTE: Bool { Self.lteMetrics.contains { field($0) != nil } }

    private var nrDetailFields: [Field] {
        (signal?.fields ?? []).filter {
            $0.key.hasPrefix("nr") && !Self.nrMetrics.contains($0.key) && !$0.value.isEmpty
        }
    }

    private var otherFields: [Field] {
        (signal?.fields ?? []).filter {
            !$0.key.hasPrefix("nr") && !Self.lteMetrics.contains($0.key)
                && !Self.lteDetails.contains($0.key) && !$0.value.isEmpty
        }
    }

    private var signalBars: Double {
        guard let icon = status?["SignalIcon"], let value = Double(icon) else { return 0 }
        return min(max(value / 5, 0), 1)
    }

    /// Codes von CurrentNetworkType (vgl. huawei-lte-api, examples/device_signal.py).
    private var networkTypeName: String {
        let names = [
            "0": "Kein Netz", "1": "GSM", "2": "GPRS", "3": "EDGE", "4": "WCDMA", "5": "HSDPA",
            "6": "HSUPA", "7": "HSPA", "9": "HSPA+", "17": "HSPA+ 64QAM", "18": "HSPA+ MIMO",
            "19": "LTE", "41": "LTE CA", "101": "5G NSA", "102": "5G SA",
        ]
        guard let code = status?["CurrentNetworkType"] else { return "–" }
        return names[code] ?? "Netztyp \(code)"
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

/// Großer Messwert mit Qualitätsbalken.
struct MetricTile: View {
    let field: Field

    var body: some View {
        let parts = SignalFormat.split(field.value)
        let quality = SignalFormat.quality(key: field.key, raw: field.value)
        VStack(alignment: .leading, spacing: 6) {
            Text(SignalFormat.label(field.key))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(parts.number.isEmpty ? field.value : parts.number)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if !parts.number.isEmpty {
                    Text(parts.unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let quality {
                ProgressView(value: quality.level)
                    .tint(quality.color)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

enum SignalFormat {
    private static let labels: [String: String] = [
        "mode": "Modus", "band": "Band", "earfcn": "EARFCN", "pci": "PCI", "cell_id": "Zell-ID",
        "rsrp": "RSRP", "rsrq": "RSRQ", "sinr": "SINR", "rssi": "RSSI",
        "dlbandwidth": "DL-Bandbreite", "ulbandwidth": "UL-Bandbreite", "txpower": "Sendeleistung",
        "nrrsrp": "RSRP", "nrrsrq": "RSRQ", "nrsinr": "SINR", "nrearfcn": "NR-ARFCN",
        "nrdlbandwidth": "DL-Bandbreite", "nrulbandwidth": "UL-Bandbreite", "nrtxpower": "Sendeleistung",
    ]

    static func label(_ key: String) -> String { labels[key] ?? key }

    /// "-95dBm" → ("-95", "dBm")
    static func split(_ raw: String) -> (number: String, unit: String) {
        let number = raw.prefix { "-+0123456789.".contains($0) }
        return (String(number), String(raw.dropFirst(number.count)))
    }

    static func quality(key: String, raw: String) -> (level: Double, color: Color)? {
        guard let value = Double(split(raw).number) else { return nil }
        let range: (low: Double, high: Double, good: Double, ok: Double)
        switch key.replacingOccurrences(of: "nr", with: "") {
        case "rsrp": range = (-140, -44, -85, -105)
        case "rsrq": range = (-20, -3, -10, -15)
        case "sinr": range = (-10, 30, 13, 0)
        default: return nil
        }
        let level = min(max((value - range.low) / (range.high - range.low), 0), 1)
        let color: Color = value >= range.good ? .green : value >= range.ok ? .orange : .red
        return (level, color)
    }
}
