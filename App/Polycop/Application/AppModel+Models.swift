// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

// MARK: Models and downloads

extension AppModel {
    /// In the models' sheet while it is open. A download can outlive the sheet
    /// or start without it, and then the page says so.
    private func showModelFailure(_ message: String?) {
        if isManagingModels { modelsFailure = message } else { failure = message }
    }

    /// The model the waiting recordings need, when it is not installed yet.
    /// Waiting for it is not a failure, since the model can still arrive.
    var missingModel: Model? {
        guard let next = nextInLine, !isInstalled(next.modelFile) else { return nil }
        return ModelCatalog.model(next.modelFile)
    }

    /// Whether a recording that waits or runs needs this model, so that
    /// deleting it cannot make a queued transcription fail later.
    func isNeeded(_ file: String) -> Bool {
        entries.contains {
            $0.modelFile == file && ($0.state == .waiting || $0.state == .running)
        }
    }

    func download(_ model: Model) {
        guard !stage.isBusy, !isShuttingDown else { return }
        showModelFailure(nil)
        downloadingModel = model
        stage = .downloading(0)
        let number = beginJob()

        work = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await ModelDownloader.download(model, in: modelFolder) {
                    [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.isCurrent(number), case .downloading = self.stage
                        else {
                            return
                        }
                        self.stage = .downloading(progress)
                    }
                }
                guard isCurrent(number) else { return }
                refreshInstalled()
                finish()
            } catch is CancellationError {
                guard isCurrent(number) else { return }
                finish()
            } catch {
                guard isCurrent(number) else { return }
                // What was received is kept, so a retry continues from it.
                showModelFailure(
                    String(
                        localized:
                            "Could not download \(model.name). \(error.localizedDescription)"))
                finish()
            }
        }
    }

    /// Removes the weights and any interrupted transfer of the same model.
    func delete(_ model: Model) {
        remove(id: model.id, name: model.name) { try ModelStore.remove(model, in: modelFolder) }
    }

    func delete(_ model: ModelStore.Imported) {
        remove(id: model.id, name: model.name) {
            try ModelStore.remove(imported: model, in: modelFolder)
        }
    }

    private func remove(id: String, name: String, _ erase: () throws -> Void) {
        guard !stage.isBusy, !isShuttingDown else { return }
        // Nothing is busy, yet recordings can still be waiting, since a failed
        // history write holds up the queue. Deleting what they need would
        // turn them into failures as soon as the write is retried.
        guard !isNeeded(id) else {
            showModelFailure(
                String(
                    localized:
                        "Recordings in your library are waiting for \(name). Let them run, or remove them, before deleting it."
                ))
            return
        }
        if engineFile == id || id == ModelCatalog.qwenAligner.id { releaseEngine() }
        do {
            try erase()
            refreshInstalled()
        } catch {
            Log.models.error("could not delete a model: \(error, privacy: .private)")
            showModelFailure(
                String(localized: "Could not delete \(name). \(error.localizedDescription)"))
        }
    }

    /// Only verified catalogue weights may reach the native model parser.
    func importModel(_ source: URL) {
        guard !stage.isBusy, !isShuttingDown else { return }
        showModelFailure(nil)
        stage = .loading
        let number = beginJob()
        releaseEngine()

        work = Task { [weak self] in
            guard let self else { return }
            do {
                let installed = try await ModelStore.install(source, in: modelFolder)
                guard isCurrent(number) else { return }
                refreshInstalled()
                // The aligner is no model to transcribe with.
                if ModelCatalog.model(installed.id) != nil { selected = installed.id }
                finish()
            } catch is CancellationError {
                guard isCurrent(number) else { return }
                finish()
            } catch {
                guard isCurrent(number) else { return }
                showModelFailure(
                    String(
                        localized:
                            "Could not import \(source.lastPathComponent). \(error.localizedDescription)"
                    ))
                finish()
            }
        }
    }

    /// The engine that runs this model, opened unless the one loaded serves.
    func preparedEngine(for model: Model, skipsSilence: Bool) async throws
        -> any TranscriptionEngine
    {
        try Task.checkCancellation()
        // Qwen times its sentences when the aligner is installed, which is
        // part of the engine it opens.
        let aligner = ModelCatalog.qwenAligner
        let aligns =
            model.engine == .qwen && ModelStore.isInstalled(aligner, in: modelFolder)
            && Memory.areLikelyToFit(model, aligner)
        if engineFile != model.id || engineSkipsSilence != skipsSilence || engineAligns != aligns
            || (engine as? WhisperEngine)?.isUsable == false
        {
            releaseEngine()
        }
        if let engine { return engine }
        stage = .loading
        let opened = try await engines.open(model, aligns)
        try Task.checkCancellation()
        engine = opened
        engineFile = model.id
        engineSkipsSilence = skipsSilence
        engineAligns = aligns
        return opened
    }

    func releaseEngine() {
        engine = nil
        engineFile = nil
        engineSkipsSilence = nil
        engineAligns = nil
    }
}
