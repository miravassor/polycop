// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where the queue learns which models are installed and opens the engine
/// that runs one. The app reads the models in Application Support; tests give
/// a scripted engine, so the queue runs where no model is installed.
struct Engines {
    var installed: () -> Set<String>
    /// Opens the engine for a model, with Qwen's aligner when `aligns`.
    var open: (_ model: Model, _ aligns: Bool) async throws -> any TranscriptionEngine

    static let live = Engines(
        installed: { Set(ModelStore.installed().map(\.id)) },
        open: { model, aligns in
            let file = ModelStore.location(of: model)
            guard model.engine != .whisper else {
                return try await WhisperEngine.load(model: file, expecting: model)
            }
            let aligner = ModelCatalog.qwenAligner
            return try await AudioCppEngine.load(
                model: file, expecting: model,
                aligner: aligns ? (ModelStore.location(of: aligner), aligner) : nil)
        })
}
