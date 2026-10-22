import CoreLocation
@testable import OpenWaze
import XCTest

final class PhotonTests: XCTestCase {
    /// Trimmed real response for "Marina Bay Sands", plus edge cases: a
    /// nameless address, a blank name with a blank city, and features that
    /// must be skipped (no usable name, malformed geometry, no OSM id).
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
       "geometry": {"type": "Point", "coordinates": [103.8, 1.3]}},
      {"type": "Feature",
       "properties": {"osm_type": "N", "osm_id": 8, "name": "Broken"},
       "geometry": {"type": "Point", "coordinates": "oops"}},
      {"type": "Feature",
       "properties": {"osm_type": "N", "name": "No ID"},
       "geometry": {"type": "Point", "coordinates": [101.7, 3.1]}},
      {"type": "Feature",
       "properties": {"osm_type": "W", "osm_id": 5, "name": "  ", "street": "Jalan Ampang",
         "city": " ", "district": "Kuala Lumpur", "country": "Malaysia"},
       "geometry": {"type": "Point", "coordinates": [101.7116, 3.1579]}}
    ]}
    """.utf8)

    func testParsesGoodFeaturesAndSkipsBadOnes() throws {
        XCTAssertEqual(try Photon.parse(fixture), [
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
            Destination(
                id: "W5", name: "Jalan Ampang",
                address: "Kuala Lumpur, Malaysia",
                latitude: 3.1579, longitude: 101.7116
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
        XCTAssertEqual(address(.init(district: "Bukit Bintang", city: "  ")), "Bukit Bintang")
        XCTAssertEqual(address(.init(city: " ", country: "Malaysia"), street: "Jalan 1"), "Jalan 1, Malaysia")
        XCTAssertEqual(address(.init(city: "Spot", country: "Spot")), "")
    }

    func testURLEncodesQueryAndRoundsLocationBias() {
        let klcc = CLLocationCoordinate2D(latitude: 3.15794, longitude: 101.71163)
        XCTAssertEqual(Photon.url(query: "Marina Bay & Sands", near: klcc).absoluteString,
                       "https://photon.komoot.io/api/?q=Marina%20Bay%20%26%20Sands&lat=3.16&lon=101.71&limit=8")
        XCTAssertEqual(Photon.url(query: "7+11", near: nil).absoluteString,
                       "https://photon.komoot.io/api/?q=7%2B11&limit=8")
        XCTAssertEqual(Photon.rounded(103.8607226), "103.86")
    }

    func testSearchSendsUserAgentAndParses() async throws {
        var sent: URLRequest?
        let results = try await Photon.search("x", near: nil) { request in
            sent = request
            return (self.fixture, Self.response(status: 200))
        }
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "User-Agent"), HTTP.userAgent)
        XCTAssertEqual(results.count, 3)
    }

    func testSearchThrowsOnHTTPError() async {
        do {
            _ = try await Photon.search("x", near: nil) { _ in (Data(), Self.response(status: 503)) }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? PhotonError, .http(status: 503))
        }
    }

    private static func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: Photon.baseURL, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
