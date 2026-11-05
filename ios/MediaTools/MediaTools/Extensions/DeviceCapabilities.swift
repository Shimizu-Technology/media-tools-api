import UIKit

/// Whether this device has an Action Button, so nothing tells a person to press a
/// button their phone doesn't have. iOS offers no API for this, so it reads the model:
/// the iPhone 15 Pro models, and every iPhone from the 16 family on.
enum ActionButtonSupport {
    static var isAvailable: Bool {
        isAvailable(modelIdentifier: currentModelIdentifier)
    }

    static func isAvailable(modelIdentifier: String) -> Bool {
        guard modelIdentifier.hasPrefix("iPhone") else { return false }
        let numbers = modelIdentifier.dropFirst("iPhone".count).split(separator: ",")
        guard numbers.count == 2, let major = Int(numbers[0]), let minor = Int(numbers[1]) else {
            return false
        }
        if major == 16 { return minor == 1 || minor == 2 }
        return major > 16
    }

    private static var currentModelIdentifier: String {
        // A simulator's own machine is the Mac, so it names the model it stands in for.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
