import CoreLocation
@testable import OpenWaze
import XCTest

final class PhotonTests: XCTestCase {
    /// Trimmed real response for "Marina Bay Sands", plus two edge cases:
    /// a nameless address and a feature with no usable name at all.
    let fixture = Data("""
    {"type": "FeatureCollection", "features": [
      {"type": "Feature",
       "properties": {"osm_type": "N", "osm_id": 4302905987, "name": "Marina Bay Sands",
         "housenumber": "10", "street": "Bayfront Avenue", "locality": "Bayfront",
         "district": "Downtown Core", "city": "Singapore", "country": "Singapore",
         "postcode": "018956", "countrycode": "SG"},
       "geometry": {"type": "Point", "coordinates": [103.8607226, 1.2836965]}},
      {"type": "Feature",
       "properties": {"osm_type": "W", "osm_id": 42, "housenumber": "1",
         "street": "Raffles Place", "district": "Downtown Core", "country": "Singapore"},
       "geometry": {"type": "Point", "coordinates": [103.851, 1.284]}},
      {"type": "Feature",
       "properties": {"osm_type": "R", "osm_id": 7, "country": "Singapore"},
       "geometry": {"type": "Point", "coordinates": [103.8, 1.3]}}
    ]}
    """.utf8)

    func testParsesFeaturesIntoDestinations() throws {
        let results = try Photon.parse(fixture)
        XCTAssertEqual(results, [
            Destination(
                id: "N4302905987", name: "Marina Bay Sands",
                address: "10 Bayfront Avenue, Singapore",
                latitude: 1.2836965, longitude: 103.8607226
            ),
            Destination(
                id: "W42", name: "1 Raffles Place",
                address: "Downtown Core, Singapore",
                latitude: 1.284, longitude: 103.851
            ),
        ])
    }

    func testEmptyAndMalformedResponses() {
        XCTAssertEqual(try Photon.parse(Data(#"{"features": []}"#.utf8)), [])
        XCTAssertThrowsError(try Photon.parse(Data("<html>".utf8)))
    }

    func testShortAddressPrefersCityAndSkipsBlanksAndRepeats() {
        func address(_ props: Photon.Properties, street: String = "") -> String {
            Photon.shortAddress(name: "Spot", street: street, props: props)
        }
        XCTAssertEqual(address(.init(locality: "Bugis", district: "Rochor", city: "Singapore")), "Singapore")
        XCTAssertEqual(address(.init(locality: "Bugis", district: "Rochor")), "Rochor")
        XCTAssertEqual(address(.init(locality: "Bugis", country: "Singapore")), "Bugis, Singapore")
        XCTAssertEqual(address(.init(city: " ", country: "Malaysia"), street: "Jalan 1"), "Jalan 1, Malaysia")
        XCTAssertEqual(address(.init(city: "Spot", country: "Spot")), "")
    }

    func testURLIsBiasedToLocationAndEncodesQuery() {
        let near = CLLocationCoordinate2D(latitude: 1.5, longitude: 103.25)
        let url = Photon.url(query: "Marina Bay & Sands", near: near)
        XCTAssertEqual(url.absoluteString,
                       "https://photon.komoot.io/api/?q=Marina%20Bay%20%26%20Sands&lat=1.5&lon=103.25&limit=8")
        XCTAssertEqual(Photon.url(query: "x", near: nil).absoluteString,
                       "https://photon.komoot.io/api/?q=x&limit=8")
    }
}
