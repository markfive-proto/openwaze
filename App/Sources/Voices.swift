import AVFoundation
import SwiftUI

/// An installed speech voice, mirrored so selection can be tested without `AVFoundation`.
struct Voice: Equatable, Identifiable {
    var id: String
    var name: String
    /// BCP 47 tag, e.g. `en-GB`.
    var language: String
    /// 1 default, 2 enhanced, 3 premium (`AVSpeechSynthesisVoiceQuality` raw values).
    var quality: Int

    init(id: String, name: String, language: String, quality: Int) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
    }

    init(_ voice: AVSpeechSynthesisVoice) {
        self.init(id: voice.identifier, name: voice.name, language: voice.language, quality: voice.quality.rawValue)
    }

    /// ponytail: id-prefix heuristic; the legacy novelty voices have no flag of their own.
    var isNovelty: Bool {
        id.hasPrefix("com.apple.speech.synthesis.voice.")
    }

    var qualityName: String {
        switch quality {
        case 3: String(localized: "Premium")
        case 2: String(localized: "Enhanced")
        default: String(localized: "Default")
        }
    }
}

/// Which voice speaks the prompts: the saved one, else the best installed one for the language.
enum Voices {
    static let savedKey = "voiceIdentifier"

    static var savedID: String? {
        get { UserDefaults.standard.string(forKey: savedKey) }
        set { UserDefaults.standard.set(newValue, forKey: savedKey) }
    }

    /// Installed voices for the prompt language, best first: quality, then real
    /// voices before the novelty ones (Bells, Bubbles...), then name.
    static func candidates(_ voices: [Voice], language: Locale = .current) -> [Voice] {
        let code = language.language.languageCode?.identifier ?? ""
        return voices
            .filter { Locale(identifier: $0.language).language.languageCode?.identifier == code }
            .sorted {
                if $0.quality != $1.quality {
                    return $0.quality > $1.quality
                }
                if $0.isNovelty != $1.isNovelty {
                    return !$0.isNovelty
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    /// The saved voice if still installed, else the best candidate, else nil (iOS picks).
    static func choose(_ voices: [Voice], saved: String?, language: Locale = .current) -> Voice? {
        if let saved, let voice = voices.first(where: { $0.id == saved }) {
            return voice
        }
        return candidates(voices, language: language).first
    }

    static func current() -> AVSpeechSynthesisVoice? {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        guard let voice = choose(installed.map(Voice.init), saved: savedID) else { return nil }
        return installed.first { $0.identifier == voice.id }
    }
}

/// Picks the voice for prompts and plays a sample on tap.
struct VoicePickerView: View {
    @State private var voices = Voices.candidates(AVSpeechSynthesisVoice.speechVoices().map(Voice.init))
    @State private var selected = Voices.savedID
    private let sampler = AVSpeechSynthesizer()

    var body: some View {
        List {
            Section {
                ForEach(voices) { voice in
                    Button {
                        selected = voice.id
                        Voices.savedID = voice.id
                        play(voice)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(voice.name)
                                Text("\(voice.qualityName) · \(voice.language)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if voice.id == (selected ?? voices.first?.id) {
                                Image(systemName: "checkmark").fontWeight(.semibold)
                            }
                        }
                    }
                    .tint(.primary)
                }
            } footer: {
                Text("""
                Tap a voice to hear it. Download more voices in \
                iOS Settings > Accessibility > Spoken Content > Voices.
                """)
            }
        }
        .overlay {
            if voices.isEmpty {
                ContentUnavailableView(String(localized: "No voices for your language"), systemImage: "speaker.slash")
            }
        }
        .navigationTitle(Text("Voice"))
    }

    private func play(_ voice: Voice) {
        sampler.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: String(localized: "In 200 metres, turn left"))
        utterance.voice = AVSpeechSynthesisVoice(identifier: voice.id)
        sampler.speak(utterance)
    }
}
