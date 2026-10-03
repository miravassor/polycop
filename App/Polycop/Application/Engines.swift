// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where the queue learns which models are installed and opens the engine
/// that runs one. The app reads the models in its model folder; tests give a
/// scripted engine, so the queue runs where no model is installed.
struct Engines {
    var installed: () -> Set<String>
    /// Opens the engine for a model, with Qwen's aligner when `aligns`.
    var open: (_ model: Model, _ aligns: Bool) async throws -> any TranscriptionEngine
    /// The stretches of speech Whisper's silence detector keeps, in seconds.
    var speech:
        (_ samples: [Float], _ settings: DecodingSettings) async throws -> [ClosedRange<
            TimeInterval
        >] =
            WhisperEngine.speech

    static func live(models folder: URL) -> Engines {
        Engines(
            installed: {
                Set(ModelCatalog.all.filter { ModelStore.isInstalled($0, in: folder) }.map(\.id))
            },
            open: { model, aligns in
                let file = ModelStore.location(of: model, in: folder)
                guard model.engine != .whisper else {
                    return try await WhisperEngine.load(model: file, expecting: model)
                }
                let aligner = ModelCatalog.qwenAligner
                return try await AudioCppEngine.load(
                    model: file, expecting: model,
                    aligner: aligns ? (ModelStore.location(of: aligner, in: folder), aligner) : nil)
            })
    }
}
