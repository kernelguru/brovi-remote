import Foundation

/// Band-, Frequenz- und Zellsperre über /api/net/lock-freq (Router mit lock_freq_switch = 3),
/// nachgebaut nach js/lockband.js der Router-Weboberfläche.
///
/// Format (je Funktechnik `lte_info` bzw. `nr_info`):
/// ```
/// <lte_info>
///   <lock_mode>3</lock_mode>            0 = keine, 3 = Band, 1 = Frequenz, 2 = Frequenz + PCI
///   <freq_infos>
///     <freq_info><band>3</band><freq>1300</freq><pci>123</pci></freq_info> …
///   </freq_infos>
///   <all_bands>3,7,20</all_bands>       alle erlaubten Bänder inkl. reiner SCell-Bänder
/// </lte_info>
/// ```
enum RAT: String, Hashable {
    case lte, nr

    var title: String { self == .lte ? "4G LTE" : "5G NR" }
    var prefix: String { self == .lte ? "B" : "n" }
    var xmlKey: String { self == .lte ? "lte_info" : "nr_info" }
    var maxPCI: Int { self == .lte ? 503 : 1007 }
    var channelName: String { self == .lte ? "EARFCN" : "NR-ARFCN" }
}

enum LockMode: String, CaseIterable, Identifiable {
    case none = "0", band = "3", freq = "1", cell = "2"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Keine Sperre"
        case .band: return "Bänder"
        case .freq: return "Frequenz"
        case .cell: return "Frequenz + PCI (Zelle)"
        }
    }
}

enum BandRole: String, CaseIterable, Identifiable {
    case off, primary, secondary

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Aus"
        case .primary: return "PCell + SCell"
        case .secondary: return "Nur SCell"
        }
    }
}

struct FreqEntry: Identifiable, Hashable {
    var id = UUID()
    var band: String
    var freq: String
    var pci: String
}

struct LockConfig {
    static let maxEntries = 20

    let rat: RAT
    var mode: LockMode = .none
    /// Bandsperre: Rolle je Band.
    var roles: [String: BandRole] = [:]
    /// Frequenz-/Zellsperre: gesperrte Kanäle.
    var entries: [FreqEntry] = []
    /// Frequenz-/Zellsperre: zusätzlich erlaubte Bänder für Carrier Aggregation.
    var extraSCells: Set<String> = []

    init(rat: RAT) {
        self.rat = rat
    }

    /// Entspricht der Auswertung in initPageThree/initBand von lockband.js.
    init(rat: RAT, node: XMLNode) {
        self.rat = rat
        mode = LockMode(rawValue: node["lock_mode"] ?? "0") ?? .none
        let all = Self.split(node["all_bands"])
        let infos = node.child("freq_infos")?.children(named: "freq_info") ?? []
        let parsed = infos.map { FreqEntry(band: $0["band"] ?? "", freq: $0["freq"] ?? "", pci: $0["pci"] ?? "") }
        let pcell = Set(parsed.map(\.band).filter { !$0.isEmpty })
        for band in all { roles[band] = pcell.contains(band) ? .primary : .secondary }
        for band in pcell where roles[band] == nil { roles[band] = .primary }
        if mode == .freq || mode == .cell {
            entries = parsed
            extraSCells = Set(all).subtracting(pcell)
        }
    }

    var activeBands: [String] {
        Self.sorted(roles.filter { $0.value != .off }.map(\.key))
    }

    /// Fehlermeldung oder nil, wenn die Einstellung gesendet werden kann.
    func validationError(catalog: BandCatalog) -> String? {
        let name = rat.title
        switch mode {
        case .none:
            return nil
        case .band:
            if !roles.values.contains(.primary) {
                return "\(name): mindestens ein Band muss „PCell + SCell“ sein."
            }
            if activeBands.count > Self.maxEntries {
                return "\(name): höchstens \(Self.maxEntries) Bänder."
            }
            return nil
        case .freq, .cell:
            if entries.isEmpty { return "\(name): mindestens eine Frequenz eintragen." }
            if entries.count > Self.maxEntries { return "\(name): höchstens \(Self.maxEntries) Einträge." }
            for entry in entries {
                let label = "\(name) \(rat.prefix)\(entry.band)"
                guard !entry.band.isEmpty else { return "\(name): Band fehlt." }
                guard let freq = Int(entry.freq) else { return "\(label): \(rat.channelName) fehlt." }
                if let range = catalog.range(rat, band: entry.band), !range.contains(freq) {
                    return "\(label): \(rat.channelName) muss zwischen \(range.lowerBound) und \(range.upperBound) liegen."
                }
                if mode == .cell {
                    guard let pci = Int(entry.pci), (0...rat.maxPCI).contains(pci) else {
                        return "\(label): PCI muss zwischen 0 und \(rat.maxPCI) liegen."
                    }
                }
            }
            return nil
        }
    }

    /// XML wie btnSaveThree/infoPostData in lockband.js.
    var xml: String {
        var infos = ""
        var all: [String] = []
        switch mode {
        case .none:
            break
        case .band:
            all = activeBands
            for band in all where roles[band] == .primary {
                infos += "<freq_info><band>\(band.xmlEscaped)</band></freq_info>"
            }
        case .freq, .cell:
            for entry in entries {
                infos += "<freq_info><band>\(entry.band.xmlEscaped)</band><freq>\(entry.freq.xmlEscaped)</freq>"
                if mode == .cell { infos += "<pci>\(entry.pci.xmlEscaped)</pci>" }
                infos += "</freq_info>"
            }
            all = Self.sorted(Array(Set(entries.map(\.band)).union(extraSCells)))
        }
        let body = "<lock_mode>\(mode.rawValue)</lock_mode><freq_infos>\(infos)</freq_infos>"
            + "<all_bands>\(all.joined(separator: ","))</all_bands>"
        return "<\(rat.xmlKey)>\(body)</\(rat.xmlKey)>"
    }

    static func split(_ list: String?) -> [String] {
        (list ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func sorted(_ bands: [String]) -> [String] {
        bands.sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }
    }
}

/// Unterstützte Bänder und Kanalbereiche aus /config/network/bandfreqlist.xml.
struct BandCatalog {
    private var supported: [RAT: [String]] = [:]
    private var ranges: [RAT: [String: ClosedRange<Int>]] = [:]

    init() {}

    init(node: XMLNode) {
        supported[.lte] = LockConfig.split(node["lte_support_band_list"])
        supported[.nr] = LockConfig.split(node["nr_support_band_list"])
        for (rat, key) in [(RAT.lte, "lte_mode"), (RAT.nr, "nr_mode")] {
            var map: [String: ClosedRange<Int>] = [:]
            for band in node.child(key)?.children(named: "band") ?? [] {
                let bounds = (band["freq"] ?? "").split(separator: "-").compactMap { Int($0) }
                if let value = band["value"], bounds.count == 2, bounds[0] <= bounds[1] {
                    map[value] = bounds[0]...bounds[1]
                }
            }
            ranges[rat] = map
        }
    }

    func range(_ rat: RAT, band: String) -> ClosedRange<Int>? {
        ranges[rat]?[band]
    }

    /// Unterstützte Bänder; ergänzt um Bänder, die der Router aktuell gesperrt meldet.
    func bands(_ rat: RAT, including config: LockConfig) -> [String] {
        let known = supported[rat] ?? []
        let used = Array(config.roles.keys) + config.entries.map(\.band) + Array(config.extraSCells)
        return LockConfig.sorted(Array(Set(known + used.filter { !$0.isEmpty })))
    }
}
