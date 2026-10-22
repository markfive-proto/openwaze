import Foundation
import Security

/// Anonymous, random device identifier for the reports server: generated
/// once and kept in the Keychain (this device only, no iCloud sync).
enum DeviceID {
    static let current = load(service: "org.openwaze.device-id")

    static func load(service: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "deviceId",
        ]
        var item: CFTypeRef?
        var lookup = query
        lookup[kSecReturnData as String] = true
        let found = SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess
        if found, let data = item as? Data, let id = String(data: data, encoding: .utf8), !id.isEmpty {
            return id
        }
        let id = UUID().uuidString
        var add = query
        add[kSecValueData as String] = Data(id.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // ponytail: if the Keychain refuses the write, this launch still has a
        // working (if short-lived) ID; nothing else depends on it persisting.
        SecItemAdd(add as CFDictionary, nil)
        return id
    }
}
