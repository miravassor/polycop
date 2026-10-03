// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A transcription model the app can download.
///
/// Every field is pinned. The commit fixes the file behind the URL, and the
/// hash proves what arrived. Sizes are counted, not quoted from a model card.
nonisolated struct Model: Identifiable, Equatable, Sendable {
    /// File name once installed, and the identifier kept in the settings.
    let id: String
    let name: String
    /// One line, shown next to the name when choosing.
    let detail: String
    let bytes: Int64
    /// Peak memory of a full lecture, measured per model rather than
    /// extrapolated. The ratio to file size varies too much for one
    /// multiplier to fit every model.
    let peakBytes: Int64
    let sha256: String
    let license: String
    /// Whether the model is given the glossary, as an initial prompt for
    /// Whisper or as hotwords for MOSS. Qwen could read it as context but is
    /// not given it, and Voxtral reads none (see `ModelCatalog.qwen` and
    /// `ModelCatalog.moss`).
    var readsGlossary = true
    var engine = Engine.whisper

    let repository: String
    let commit: String
    let file: String

    /// Pinned to a commit, so the file behind it can never change.
    var url: URL {
        // Every component is a literal of this file, so the URL is always valid.
        // swift-format-ignore: NeverForceUnwrap
        URL(string: "https://huggingface.co/\(repository)/resolve/\(commit)/\(file)")!
    }
}

/// The family of a model, which decides the library that runs it and what it
/// can do. The window asks what a family can do, never which model it is.
nonisolated enum Engine: CaseIterable, Sendable {
    case whisper
    case qwen
    case moss
    case voxtral

    var name: String {
        switch self {
        case .qwen: "Qwen3-ASR"
        case .whisper: "Whisper"
        case .moss: "MOSS-Transcribe-Diarize"
        case .voxtral: "Voxtral Realtime"
        }
    }

    var developer: String {
        switch self {
        case .qwen: "Alibaba"
        case .whisper: "OpenAI"
        case .moss: "OpenMOSS"
        case .voxtral: "Mistral AI"
        }
    }

    /// Word following needs a time for each word, which Whisper reports and
    /// Qwen's aligner adds; MOSS and Voxtral time only whole passages.
    var features: String {
        switch self {
        case .qwen: "30-second timestamps · No glossary, subtitles or word following"
        case .whisper: "Glossaries · Sentence timestamps · Subtitles · Word following"
        case .moss: "Glossaries · Sentence timestamps · Subtitles · Speakers · No word following"
        case .voxtral: "30-second timestamps · No glossary, subtitles or word following"
        }
    }

    /// What Qwen can do once its aligner times each word.
    func features(aligned: Bool) -> String {
        aligned && self == .qwen
            ? "Sentence timestamps · Subtitles · Word following · No glossary" : features
    }

    /// What word following means, beside the features that name it.
    static let wordFollowing =
        "Word following: the word being heard is highlighted, a word can be played from with Option-click or Play From Cursor, and the text cursor can follow playback."

    /// Everything but Whisper runs through audio.cpp.
    var audioCpp: AudioCppProfile? {
        switch self {
        case .qwen: .qwen
        case .whisper: nil
        case .moss: .moss
        case .voxtral: .voxtral
        }
    }

    /// Silence removal runs inside whisper.cpp, and so does the repair of
    /// repeats, which depends on it.
    var skipsSilence: Bool { self == .whisper }

    /// Whisper and MOSS time segments about a sentence long. Qwen and Voxtral
    /// report one segment per window, correct but too long for a subtitle.
    var timesSentences: Bool { self == .whisper || self == .moss }
}

/// The models offered to the user, named after what recognises the speech
/// rather than by a technical label: OpenAI's Whisper, converted by the
/// whisper.cpp project, and Alibaba's Qwen3-ASR, OpenMOSS's
/// MOSS-Transcribe-Diarize and Mistral's Voxtral, converted by the audio.cpp
/// project.
nonisolated enum ModelCatalog {
    /// The default: fast, and it reads a glossary.
    static let recommended = turbo

    /// The model selected at launch: the recommended one when it is installed
    /// or when nothing is, so that its download is offered, and otherwise the
    /// first installed model in catalogue order.
    static func startingModel(installed: Set<String>) -> Model {
        guard !installed.contains(recommended.id),
            let available = all.first(where: { installed.contains($0.id) })
        else { return recommended }
        return available
    }

    /// Named by role rather than by technical label, so the user does not
    /// have to choose between quantisations to transcribe a lecture.
    static let all = [turbo, turboQuantized, largeV3, qwen, moss, voxtral]

    static func model(_ id: String) -> Model? {
        all.first { $0.id == id }
    }

    /// Everything the store may hold, the models plus Qwen's aligner, which
    /// transcribes nothing and so is not offered as a model.
    static let files = all + [qwenAligner]

    /// Times each word of Qwen's text, so that its segments follow sentences
    /// and subtitles can be written. The official toolkit aligns 3 minutes at
    /// most per call; Qwen's windows of 30 seconds stay well under that. The
    /// text itself is unchanged. Its peak is what it adds to Qwen's, measured
    /// on one 30-second window.
    static let qwenAligner = Model(
        id: "qwen3-forced-aligner-0.6b-q8_0.gguf",
        name: "Qwen3 Forced Aligner 0.6B",
        detail: "Timestamps for each sentence of Qwen's transcripts, and subtitles",
        bytes: 1_129_966_496,
        peakBytes: 1_060_000_000,
        sha256: "75209490b11cec2b0db749ca5f4ff92266f58efd30f7fd04d9eb2a3ac9cc929f",
        license: "Apache 2.0",
        readsGlossary: false,
        engine: .qwen,
        repository: "audio-cpp/audio.cpp-gguf",
        commit: "bd2f3e26c1a74fa359d712b4e46919fc244722c5",
        file: "Qwen3-ForcedAligner-0.6B-GGUF/qwen3-forced-aligner-0.6b-q8_0.gguf"
    )

    /// The silence detector shipped in the bundle rather than downloaded.
    /// Pinned like the others, so a test proves the committed file is still
    /// this one before whisper.cpp parses it.
    static let voiceDetector = Model(
        id: "ggml-silero-v6.2.0.bin",
        name: "Silero VAD",
        detail: "Speech detection",
        bytes: 885_098,
        // A detector, not a transcription model, so nothing measured it and
        // the memory check never sees it. Any value above its size will do.
        peakBytes: 2_000_000,
        sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987",
        license: "MIT",
        repository: "ggml-org/whisper-vad",
        commit: "9ffd54a1e1ee413ddf265af9913beaf518d1639b",
        file: "ggml-silero-v6.2.0.bin"
    )

    // OpenAI publishes the weights under MIT in its repository while the Hugging
    // Face card of large-v3 says Apache 2.0. Both are recorded rather than
    // resolved. Turbo's card says MIT, as the repository does.
    private static let openAILicense = "MIT per OpenAI, Apache 2.0 on Hugging Face"
    private static let whisperCpp = "ggerganov/whisper.cpp"
    private static let whisperCppCommit = "5359861c739e955e79d9a303bcbc70fb988958b1"

    /// Qwen is given no glossary: as context, it can copy the glossary
    /// sentence into the transcript.
    static let qwen = Model(
        id: "qwen3-asr-1.7b-q8_0.gguf",
        name: "Qwen3-ASR 1.7B",
        detail: "Timestamps for each sentence with the optional aligner",
        bytes: 2_473_010_048,
        peakBytes: 3_870_000_000,
        sha256: "da4fc2ac7f24dee784d1684eb1f35836cdbf559519452ae11777670734c0a4f8",
        license: "Apache 2.0",
        readsGlossary: false,
        engine: .qwen,
        repository: "audio-cpp/audio.cpp-gguf",
        commit: "bd2f3e26c1a74fa359d712b4e46919fc244722c5",
        file: "Qwen3-ASR-1.7B-GGUF/qwen3-asr-1.7b-q8_0.gguf"
    )

    /// Reads the course glossary as hotwords, in the form of the official toolkit.
    static let moss = Model(
        id: "moss-transcribe-diarize-q8_0.gguf",
        name: "MOSS-Transcribe-Diarize 0.9B",
        detail: "Labels speaker turns and times each sentence",
        bytes: 1_132_110_560,
        peakBytes: 5_600_000_000,
        sha256: "93eea5865615e270b827752945f2dfd0f522ed673f4f551675e9013170173679",
        license: "Apache 2.0",
        engine: .moss,
        repository: "audio-cpp/audio.cpp-gguf",
        commit: "bd2f3e26c1a74fa359d712b4e46919fc244722c5",
        file: "MOSS-Transcribe-Diarize-GGUF/moss-transcribe-diarize-q8_0.gguf"
    )

    /// Runs streamed, as it is meant to run, because offline it leaves out
    /// whole passages of audio. About as slow as the recording is long.
    static let voxtral = Model(
        id: "voxtral-mini-4b-realtime-2602-q8_0.gguf",
        name: "Voxtral Mini 4B Realtime",
        detail: "Streamed. Takes about as long as the recording",
        bytes: 5_104_567_264,
        peakBytes: 5_970_000_000,
        sha256: "0312a5ceafc6ee4a19a32da458cab6485e3b86b1b563c7bb7150aeae295c1769",
        license: "Apache 2.0",
        readsGlossary: false,
        engine: .voxtral,
        repository: "audio-cpp/audio.cpp-gguf",
        commit: "bd2f3e26c1a74fa359d712b4e46919fc244722c5",
        file: "Voxtral-Mini-4B-Realtime-2602-GGUF/voxtral-mini-4b-realtime-2602-q8_0.gguf"
    )

    static let turbo = Model(
        id: "ggml-large-v3-turbo.bin",
        name: "Whisper Large v3 turbo",
        detail: "Recommended. Fast, and reads a glossary",
        bytes: 1_624_555_275,
        peakBytes: 2_810_000_000,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        license: "MIT",
        repository: whisperCpp,
        commit: whisperCppCommit,
        file: "ggml-large-v3-turbo.bin"
    )

    static let largeV3 = Model(
        id: "ggml-large-v3.bin",
        name: "Whisper Large v3",
        detail: "The full Whisper model. About three times slower than turbo",
        bytes: 3_095_033_483,
        peakBytes: 5_020_000_000,
        sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
        license: openAILicense,
        repository: whisperCpp,
        commit: whisperCppCommit,
        file: "ggml-large-v3.bin"
    )

    static let turboQuantized = Model(
        id: "ggml-large-v3-turbo-q8_0.bin",
        name: "Whisper Large v3 turbo quantized",
        detail: "Fast. About half the download, a quarter less memory",
        bytes: 874_188_075,
        peakBytes: 2_040_000_000,
        sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1",
        license: "MIT",
        repository: whisperCpp,
        commit: whisperCppCommit,
        file: "ggml-large-v3-turbo-q8_0.bin"
    )
}
