import Foundation

/// Umrechnung zwischen Huawei-Bandmasken (Hex, Bit n-1 = Band n) und Bandnummern.
enum BandMask {
    static let allBands = "7FFFFFFFFFFFFFFF"

    static func bands(fromHex hex: String) -> Set<Int> {
        var cleaned = hex.uppercased()
        if cleaned.hasPrefix("0X") { cleaned.removeFirst(2) }
        var result = Set<Int>()
        for (nibbleIndex, char) in cleaned.reversed().enumerated() {
            guard let value = Int(String(char), radix: 16) else { continue }
            for bit in 0..<4 where value & (1 << bit) != 0 {
                result.insert(nibbleIndex * 4 + bit + 1)
            }
        }
        return result
    }

    static func hex(from bands: Set<Int>) -> String {
        guard let highest = bands.max(), highest > 0 else { return "0" }
        let nibbleCount = (highest - 1) / 4 + 1
        var hex = ""
        for nibble in (0..<nibbleCount).reversed() {
            var value = 0
            for bit in 0..<4 where bands.contains(nibble * 4 + bit + 1) {
                value |= 1 << bit
            }
            hex += String(value, radix: 16, uppercase: true)
        }
        return hex
    }
}
