@testable import OpenWaze
import XCTest

final class VoicesTests: XCTestCase {
    private let english = Locale(identifier: "en_MY")
    private let compact = Voice(id: "en-compact", name: "Daniel", language: "en-GB", quality: 1)
    private let enhanced = Voice(id: "en-enhanced", name: "Aaron", language: "en-US", quality: 2)
    private let premium = Voice(id: "en-premium", name: "Zoe", language: "en-US", quality: 3)
    private let malay = Voice(id: "ms", name: "Amira", language: "ms-MY", quality: 3)

    func testCandidatesAreTheLanguagesVoicesBestFirst() {
        let got = Voices.candidates([compact, malay, enhanced, premium], language: english)
        XCTAssertEqual(got.map(\.id), ["en-premium", "en-enhanced", "en-compact"])
    }

    func testCandidatesTieBreakByName() {
        let bob = Voice(id: "b", name: "Bob", language: "en-AU", quality: 1)
        XCTAssertEqual(Voices.candidates([compact, bob], language: english).map(\.id), ["b", "en-compact"])
    }

    func testNoveltyVoicesRankAfterRealOnesOfTheSameQuality() {
        let bells = Voice(id: "com.apple.speech.synthesis.voice.Bells", name: "Bells", language: "en-US", quality: 1)
        let samantha = Voice(id: "com.apple.voice.compact.en-US.Sam", name: "Samantha", language: "en-US", quality: 1)
        XCTAssertEqual(Voices.candidates([bells, samantha], language: english).map(\.name), ["Samantha", "Bells"])
        XCTAssertEqual(Voices.choose([bells, samantha], saved: nil, language: english)?.name, "Samantha")
    }

    func testNoChoiceUsesBestInstalledNotTheCompactDefault() {
        XCTAssertEqual(Voices.choose([compact, enhanced, malay], saved: nil, language: english)?.id, "en-enhanced")
    }

    func testSavedVoiceWins() {
        XCTAssertEqual(Voices.choose([compact, premium], saved: "en-compact", language: english)?.id, "en-compact")
    }

    func testUninstalledSavedVoiceFallsBackToBest() {
        XCTAssertEqual(Voices.choose([compact, premium], saved: "gone", language: english)?.id, "en-premium")
    }

    func testNoVoiceForTheLanguageIsNil() {
        XCTAssertNil(Voices.choose([malay], saved: nil, language: english))
        XCTAssertNil(Voices.choose([], saved: "en-premium", language: english))
    }
}
