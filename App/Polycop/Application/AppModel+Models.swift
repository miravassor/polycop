// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

// MARK: Models and downloads

extension AppModel {
    func download(_ model: Model) {
        guard !stage.isBusy, !isShuttingDown else { return }
        failure = nil
        downloadingModel = model
        stage = .downloading(0)
        let number = beginJob()

        work = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await ModelDownloader.download(model) { [weak self] progress in
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
                failure = error.localizedDescription
                finish()
            }
        }
    }

    /// Removes the weights and any interrupted transfer of the same model.
    func delete(_ model: Model) {
        remove(named: model.id) { try ModelStore.remove(model) }
    }

    func delete(_ model: ModelStore.Imported) {
        remove(named: model.id) { try ModelStore.remove(imported: model) }
    }

    private func remove(named name: String, _ erase: () throws -> Void) {
        guard !stage.isBusy, !isShuttingDown else { return }
        // Nothing is busy, yet recordings can still be waiting, since a failed
        // history write holds up the queue. Deleting what they need would
        // turn them into failures as soon as the write is retried.
        guard !isNeeded(name) else {
            failure = String(
                localized:
                    "Recordings in your library are waiting for this model. Let them run, or remove them, before deleting it."
            )
            return
        }
        if engineFile == name || name == ModelCatalog.qwenAligner.id { releaseEngine() }
        do {
            try erase()
            refreshInstalled()
        } catch {
            Log.models.error("could not delete a model: \(error, privacy: .private)")
            failure = error.localizedDescription
        }
    }

    /// Only verified catalogue weights may reach the native model parser.
    func importModel(_ source: URL) {
        guard !stage.isBusy, !isShuttingDown else { return }
        failure = nil
        stage = .loading
        let number = beginJob()
        releaseEngine()

        work = Task { [weak self] in
            guard let self else { return }
            do {
                let installed = try await ModelStore.install(source)
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
                failure = error.localizedDescription
                finish()
            }
        }
    }
}
