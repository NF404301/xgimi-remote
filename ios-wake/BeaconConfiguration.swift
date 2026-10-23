import Foundation

// Local device configuration. Public builds leave the default empty.
enum BeaconConfiguration {
    static let defaultMAC = ""
    static var currentMAC: String { UserDefaults.standard.string(forKey: "projectorBluetoothMAC") ?? defaultMAC }

    static func normalize(_ address: String) throws -> String {
        let compact = address.uppercased().filter { $0 != ":" && $0 != "-" && !$0.isWhitespace }
        guard compact.count == 12, compact.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (65...70).contains($0.value) }) else {
            throw ConfigurationError.invalidMAC
        }
        let characters = Array(compact)
        return stride(from: 0, to: 12, by: 2).map { String(characters[$0...($0 + 1)]) }.joined(separator: ":")
    }
    static func uuid(for address: String) throws -> UUID {
        let parts = try normalize(address).split(separator: ":").map(String.init)
        let raw = Array((parts.reversed().joined() + "FFFFFF3343524B544D00").uppercased())
        var index = 0
        let groups = [8, 4, 4, 4, 12].map { size -> String in
            defer { index += size }
            return String(raw[index..<(index + size)])
        }
        guard let id = UUID(uuidString: groups.joined(separator: "-")) else { throw ConfigurationError.invalidMAC }
        return id
    }
    static func save(_ address: String) throws {
        UserDefaults.standard.set(try normalize(address), forKey: "projectorBluetoothMAC")
    }
    enum ConfigurationError: LocalizedError {
        case invalidMAC
        var errorDescription: String? { "请先在连接设置中填写投影仪蓝牙 MAC 地址，例如 02:11:22:33:44:55" }
    }
}
