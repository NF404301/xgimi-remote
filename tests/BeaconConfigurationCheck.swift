import Foundation
@main struct BeaconConfigurationCheck {
    static func main() throws {
        let id = try BeaconConfiguration.uuid(for: "02:11:22:33:44:55")
        precondition(id.uuidString == "55443322-1102-FFFF-FF33-43524B544D00")
        let normalized = try BeaconConfiguration.normalize("02-11-22-33-44-55")
        precondition(normalized == "02:11:22:33:44:55")
        for value in ["", "GG:11:22:33:44:55", "123", "02:11:22:33:44:5555"] {
            do { _ = try BeaconConfiguration.uuid(for: value); fatalError("Invalid address was accepted") } catch {}
        }
        print("Beacon configuration checks passed")
    }
}
