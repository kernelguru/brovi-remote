import SwiftUI

/// Gebündelte Zellen (Carrier Aggregation) und Nachbarzellen.
/// Quellen: /api/device/seccellinfo, /api/device/nbrcellinfo, /api/net/cell-info.
/// Format je Zelle: "Kanal,Band,[Bandbreite,]PCI,RSRP,RSRQ,RSSI,SINR;"
struct CellListsView: View {
    let client: RouterClient

    @State private var lteSecondary: [CellEntry] = []
    @State private var nrSecondary: [CellEntry] = []
    @State private var lteNeighbors: [CellEntry] = []
    @State private var nrNeighbors: [CellEntry] = []
    @State private var cellID: String?
    @State private var tac: String?

    var body: some View {
        VStack(spacing: 16) {
            if cellID != nil || !lteSecondary.isEmpty || !nrSecondary.isEmpty {
                GlassCard(title: "Zelle & Carrier Aggregation", systemImage: "square.stack.3d.up") {
                    if let cellID { cellInfo(cellID) }
                    ForEach(lteSecondary + nrSecondary) { CellRow(entry: $0) }
                    if lteSecondary.isEmpty && nrSecondary.isEmpty {
                        Text("Keine zusätzlichen Zellen gebündelt.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !lteNeighbors.isEmpty || !nrNeighbors.isEmpty {
                GlassCard(title: "Nachbarzellen", systemImage: "circle.grid.cross") {
                    ForEach(lteNeighbors + nrNeighbors) { CellRow(entry: $0) }
                }
            }
        }
        .task { await poll() }
    }

    private func cellInfo(_ hex: String) -> some View {
        let id = UInt64(hex, radix: 16)
        return VStack(spacing: 8) {
            row("Zell-ID", id.map { "\($0) (0x\(hex))" } ?? hex)
            if let id {
                row("eNB / Sektor", "\(id >> 8) / \(id & 0xFF)")
            }
            if let tac, !tac.isEmpty { row("TAC", tac) }
        }
        .font(.subheadline)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func load() async {
        if let node = try? await client.get("/api/device/seccellinfo") {
            lteSecondary = CellEntry.parse(node["lteseccell_list"], rat: "4G", withBandwidth: true)
            nrSecondary = CellEntry.parse(node["nrseccell_list"], rat: "5G", withBandwidth: true)
        }
        if let node = try? await client.get("/api/device/nbrcellinfo") {
            lteNeighbors = CellEntry.parse(node["nbrcell_ltelist"], rat: "4G", withBandwidth: false)
            nrNeighbors = CellEntry.parse(node["nbrcell_nrlist"], rat: "5G", withBandwidth: false)
        }
        if let node = try? await client.get("/api/net/cell-info") {
            cellID = node["cellinfo"].flatMap { $0.isEmpty ? nil : $0 }
            tac = node["lac"]
        }
    }
}

struct CellEntry: Identifiable {
    let id: String
    let rat: String
    let channel: String
    let band: String
    let bandwidth: String?
    let pci: String
    let rsrp: String
    let rsrq: String
    let rssi: String
    let sinr: String

    static func parse(_ list: String?, rat: String, withBandwidth: Bool) -> [CellEntry] {
        let count = withBandwidth ? 8 : 7
        return (list ?? "").split(separator: ";").enumerated().compactMap { index, item in
            let parts = item.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= count else { return nil }
            let offset = withBandwidth ? 1 : 0
            return CellEntry(
                id: "\(rat)-\(index)-\(item)",
                rat: rat,
                channel: parts[0],
                band: parts[1],
                bandwidth: withBandwidth ? parts[2] : nil,
                pci: parts[2 + offset],
                rsrp: parts[3 + offset],
                rsrq: parts[4 + offset],
                rssi: parts[5 + offset],
                sinr: parts[6 + offset]
            )
        }
    }
}

private struct CellRow: View {
    let entry: CellEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.band)
                    .font(.headline)
                    .foregroundStyle(Theme.cyan)
                if let bandwidth = entry.bandwidth {
                    Text(bandwidth).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Kanal \(entry.channel) · PCI \(entry.pci)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                metric("RSRP", entry.rsrp, key: "rsrp")
                metric("RSRQ", entry.rsrq, key: "rsrq")
                metric("SINR", entry.sinr, key: "sinr")
                metric("RSSI", entry.rssi, key: "rssi")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func metric(_ label: String, _ value: String, key: String) -> some View {
        let quality = SignalFormat.quality(key: key, raw: value)
        return VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value == "--" ? "–" : value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(quality?.color ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
