import Foundation
import Security

/// Anonymous, random device identifier for the reports server, kept in the
/// Keychain (this device only, no iCloud sync).
///
/// A soft identifier: it rate-limits honest clients, not attackers; real
/// abuse control is App Attest (#46).
///
/// Privacy: a reinstall gets a new ID. iOS keeps Keychain items across
/// reinstalls but wipes UserDefaults, so a missing install marker means a
/// fresh install and any old item is deleted first.
final class DeviceID: @unchecked Sendable {
    static let shared = DeviceID(service: "org.openwaze.device-id")

    let service: String
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: String?

    init(service: String, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    /// The ID, or nil while the Keychain is locked (before first unlock);
    /// the next call tries again rather than minting a new ID.
    var value: String? {
        lock.withLock {
            if cached == nil {
                cached = loadOrCreate()
            }
            return cached
        }
    }

    /// Forgets the in-memory copy, so the next read goes to storage (tests).
    func clearCache() {
        lock.withLock { cached = nil }
    }

    private var markerKey: String {
        "installMarker.\(service)"
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "deviceId",
        ]
    }

    private func loadOrCreate() -> String? {
        if !defaults.bool(forKey: markerKey) {
            let deleted = SecItemDelete(query as CFDictionary)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else { return nil }
        }
        var lookup = query
        lookup[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let id = String(data: data, encoding: .utf8),
           !id.isEmpty {
            defaults.set(true, forKey: markerKey)
            return id
        }
        // Locked (errSecInteractionNotAllowed) or another error: retry later.
        guard status == errSecItemNotFound || status == errSecSuccess else { return nil }
        if status == errSecSuccess {
            SecItemDelete(query as CFDictionary) // unreadable item: replace it
        }
        let id = UUID().uuidString
        var add = query
        add[kSecValueData as String] = Data(id.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        defaults.set(true, forKey: markerKey)
        return id
    }
}
