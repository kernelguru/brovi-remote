import SwiftUI

/// Band-, Frequenz- und Zellsperre für 4G und 5G (siehe FrequencyLock.swift).
struct LockView: View {
    let client: RouterClient

    @State private var lte = LockConfig(rat: .lte)
    @State private var nr = LockConfig(rat: .nr)
    @State private var hasLTE = false
    @State private var hasNR = false
    @State private var networkMode = ""
    @State private var catalog = BandCatalog()
    @State private var loadedOnce = false
    @State private var message: String?
    @State private var isError = false
    @State private var busy = false
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            Form {
                if let message {
                    Section {
                        Text(message).foregroundStyle(isError ? .red : .green)
                    }
                }

                if loadedOnce && !hasLTE && !hasNR {
                    Section {
                        Text("Der Router liefert keine Sperr-Einstellungen (lte_info/nr_info). Rohdaten siehe API-Tab: /api/net/lock-freq.")
                            .foregroundStyle(.secondary)
                    }
                }

                if hasLTE {
                    LockSection(config: $lte, bands: catalog.bands(.lte, including: lte), catalog: catalog,
                                inactiveReason: networkMode == "08" ? "Im Netzmodus „Nur 5G“ wird die 4G-Sperre nicht gesendet." : nil)
                }
                if hasNR {
                    LockSection(config: $nr, bands: catalog.bands(.nr, including: nr), catalog: catalog,
                                inactiveReason: networkMode == "03" ? "Im Netzmodus „Nur 4G“ wird die 5G-Sperre nicht gesendet." : nil)
                }

                Section {
                    Button("Übernehmen") { validateAndConfirm() }
                        .disabled(busy || !(hasLTE || hasNR))
                    Button("Alle Sperren aufheben", role: .destructive) {
                        lte.mode = .none
                        nr.mode = .none
                        validateAndConfirm()
                    }
                    .disabled(busy || !(hasLTE || hasNR))
                    Button("Neu laden") { Task { await load() } }
                        .disabled(busy)
                } footer: {
                    Text("PCell = Ankerzelle, SCell = zusätzliche Zelle für Carrier Aggregation. Falsche Sperren können die Verbindung trennen – „Alle Sperren aufheben“ stellt den Normalzustand wieder her.")
                }
            }
            .appBackground()
            .navigationTitle("Sperre")
            .toolbar {
                if busy {
                    ToolbarItem(placement: .primaryAction) { ProgressView() }
                }
            }
            .confirmationDialog("Sperre übernehmen?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Übernehmen") { Task { await apply() } }
            } message: {
                Text("Der Router verbindet sich neu, das kann bis zu einer Minute dauern.")
            }
            .task { if !loadedOnce { await load() } }
        }
    }

    private var sendsLTE: Bool { hasLTE && networkMode != "08" }
    private var sendsNR: Bool { hasNR && networkMode != "03" }

    private func load() async {
        busy = true
        defer { busy = false; loadedOnce = true }
        do {
            let node = try await client.get("/api/net/lock-freq")
            if let info = node.child("lte_info") { lte = LockConfig(rat: .lte, node: info); hasLTE = true } else { hasLTE = false }
            if let info = node.child("nr_info") { nr = LockConfig(rat: .nr, node: info); hasNR = true } else { hasNR = false }
            if let list = try? await client.get("/config/network/bandfreqlist.xml") {
                catalog = BandCatalog(node: list)
            }
            networkMode = (try? await client.get("/api/net/net-mode"))?["NetworkMode"] ?? ""
            message = nil
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    private func validateAndConfirm() {
        let configs = [sendsLTE ? lte : nil, sendsNR ? nr : nil].compactMap { $0 }
        if let problem = configs.lazy.compactMap({ $0.validationError(catalog: catalog) }).first {
            show(problem, isError: true)
            return
        }
        confirm = true
    }

    private func apply() async {
        busy = true
        show("Router verbindet sich neu …", isError: false)
        var inner = ""
        if sendsLTE { inner += lte.xml }
        if sendsNR { inner += nr.xml }
        do {
            _ = try await client.post("/api/net/lock-freq", inner, timeout: 90)
            busy = false
            await load()
            show("Sperre gespeichert.", isError: false)
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

private struct LockSection: View {
    @Binding var config: LockConfig
    let bands: [String]
    let catalog: BandCatalog
    let inactiveReason: String?

    private var rat: RAT { config.rat }

    var body: some View {
        Section {
            Picker("Sperre", selection: $config.mode) {
                ForEach(LockMode.allCases) { Text($0.label).tag($0) }
            }

            switch config.mode {
            case .none:
                EmptyView()
            case .band:
                ForEach(bands, id: \.self) { band in
                    Picker("\(rat.prefix)\(band)", selection: roleBinding(band)) {
                        ForEach(BandRole.allCases) { Text($0.label).tag($0) }
                    }
                }
            case .freq, .cell:
                ForEach($config.entries) { $entry in
                    FreqEntryRow(entry: $entry, rat: rat, bands: bands, catalog: catalog, withPCI: config.mode == .cell)
                }
                .onDelete { config.entries.remove(atOffsets: $0) }
                Button {
                    config.entries.append(FreqEntry(band: bands.first ?? "", freq: "", pci: ""))
                } label: {
                    Label(config.mode == .cell ? "Zelle hinzufügen" : "Frequenz hinzufügen", systemImage: "plus")
                }
                .disabled(config.entries.count >= LockConfig.maxEntries)
                DisclosureGroup("Zusätzliche SCell-Bänder (\(config.extraSCells.count))") {
                    ForEach(bands, id: \.self) { band in
                        Toggle("\(rat.prefix)\(band)", isOn: scellBinding(band))
                    }
                }
            }
        } header: {
            Text(rat.title)
        } footer: {
            if let inactiveReason {
                Text(inactiveReason)
            } else {
                Text(footer)
            }
        }
        .disabled(inactiveReason != nil)
    }

    private var footer: String {
        switch config.mode {
        case .none: return "Der Router wählt Bänder und Zellen selbst."
        case .band: return "Nur die gewählten Bänder werden genutzt."
        case .freq: return "Nur die eingetragenen Kanäle (\(rat.channelName)) werden als Ankerzelle genutzt. Zum Löschen nach links wischen."
        case .cell: return "Sperrt auf eine bestimmte Zelle (Kanal + PCI 0–\(rat.maxPCI)). Zum Löschen nach links wischen."
        }
    }

    private func roleBinding(_ band: String) -> Binding<BandRole> {
        Binding(
            get: { config.roles[band] ?? .off },
            set: { config.roles[band] = $0 }
        )
    }

    private func scellBinding(_ band: String) -> Binding<Bool> {
        Binding(
            get: { config.extraSCells.contains(band) },
            set: { enabled in
                if enabled { config.extraSCells.insert(band) } else { config.extraSCells.remove(band) }
            }
        )
    }
}

private struct FreqEntryRow: View {
    @Binding var entry: FreqEntry
    let rat: RAT
    let bands: [String]
    let catalog: BandCatalog
    let withPCI: Bool

    private let mono = Font.system(.body, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Band", selection: $entry.band) {
                if !bands.contains(entry.band) {
                    Text(entry.band.isEmpty ? "–" : "\(rat.prefix)\(entry.band)").tag(entry.band)
                }
                ForEach(bands, id: \.self) { Text("\(rat.prefix)\($0)").tag($0) }
            }
            LabeledContent(rat.channelName) {
                TextField(rangeHint, text: $entry.freq)
                    .font(mono)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            if withPCI {
                LabeledContent("PCI") {
                    TextField("0–\(rat.maxPCI)", text: $entry.pci)
                        .font(mono)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var rangeHint: String {
        guard let range = catalog.range(rat, band: entry.band) else { return "Kanal" }
        return "\(range.lowerBound)–\(range.upperBound)"
    }
}
