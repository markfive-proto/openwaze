import Foundation

/// Helpers shared by the HTTP clients (Photon, Router, ReportsClient).
enum HTTP {
    static let userAgent = "OpenWaze/0.1 (+https://github.com/markfive-proto/openwaze)"

    /// Decodes to nil instead of throwing, so one bad element is dropped alone.
    struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}
