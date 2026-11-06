// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

/// The list of models shows one failure under all its rows, so each says what
/// it is about.
@MainActor
final class ModelFailureTests {
    private let root = URL.temporaryDirectory.appending(path: UUID().uuidString)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func model(models: URL) -> AppModel {
        AppModel(
            history: root.appending(path: "History"),
            glossaries: root.appending(path: "Glossaries"),
            models: models, playbackCopies: root.appending(path: "Replay"))
    }

    private func settled(_ model: AppModel) async throws {
        for _ in 0..<500 where model.stage.isBusy {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.stage.isBusy)
    }

    /// A store that cannot be made fails before any request, so this needs no network.
    @Test func aFailedDownloadNamesTheModel() async throws {
        let file = root.appending(path: "file")
        try Data().write(to: file)
        let app = model(models: file.appending(path: "Models"))

        app.download(ModelCatalog.recommended)
        try await settled(app)

        #expect(
            app.failure?.hasPrefix("Could not download \(ModelCatalog.recommended.name). ") == true)
        await app.shutDown()
    }

    @Test func aRefusedImportNamesTheFile() async throws {
        let file = root.appending(path: "notes.txt")
        try Data("not a model".utf8).write(to: file)
        let app = model(models: root.appending(path: "Models"))

        app.importModel(file)
        try await settled(app)

        #expect(app.failure?.hasPrefix("Could not import notes.txt. ") == true)
        await app.shutDown()
    }

    @Test func theSheetKeepsItsFailureFromThePageBehindIt() async {
        let app = model(models: root.appending(path: "Models"))
        app.isManagingModels = true

        app.delete(ModelStore.Imported(id: "gone.bin", bytes: 1))

        #expect(app.modelsFailure?.hasPrefix("Could not delete gone. ") == true)
        #expect(app.failure == nil)

        app.isManagingModels = false

        #expect(app.modelsFailure == nil)
        #expect(app.failure == nil)
        await app.shutDown()
    }

    @Test func openingTheSheetLeavesThePageFailureBehind() async {
        let app = model(models: root.appending(path: "Models"))
        app.delete(ModelStore.Imported(id: "gone.bin", bytes: 1))
        #expect(app.failure != nil)

        app.isManagingModels = true

        #expect(app.failure == nil)
        await app.shutDown()
    }

    /// The sheet belongs to the page, so coming back must not reopen it.
    @Test func leavingThePageClosesTheSheet() async {
        let app = model(models: root.appending(path: "Models"))
        app.isManagingModels = true

        app.pane = .entry(UUID())

        #expect(!app.isManagingModels)
        await app.shutDown()
    }

    @Test func aFailedDeletionNamesTheModel() async {
        let app = model(models: root.appending(path: "Models"))

        app.delete(ModelStore.Imported(id: "gone.bin", bytes: 1))

        #expect(app.failure?.hasPrefix("Could not delete gone. ") == true)
        await app.shutDown()
    }
}
