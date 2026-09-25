// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import Testing
import os

@testable import Polycop

private let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")

private func isHexadecimal(_ text: String, length: Int) -> Bool {
    text.count == length && CharacterSet(charactersIn: text).isSubset(of: hexadecimal)
}

@Test func theCatalogueHasNoDuplicates() {
    #expect(Set(ModelCatalog.all.map(\.id)).count == ModelCatalog.all.count)
    #expect(Set(ModelCatalog.all.map(\.name)).count == ModelCatalog.all.count)
    #expect(ModelCatalog.all.contains(ModelCatalog.recommended))
}

/// A model is only trustworthy if the file behind its URL cannot change and its
/// contents can be proven, so every entry carries a commit and a hash.
@Test(arguments: ModelCatalog.all)
func everyModelIsPinned(_ model: Model) {
    #expect(isHexadecimal(model.sha256, length: 64))
    #expect(isHexadecimal(model.commit, length: 40))
    #expect(model.bytes > 0)
    #expect(!model.license.isEmpty)

    #expect(model.url.scheme == "https")
    #expect(model.url.host() == "huggingface.co")
    #expect(model.url.path().contains(model.commit))
}

@Test func aModelIsStoredUnderItsOwnName() {
    let location = ModelStore.location(of: ModelCatalog.recommended)

    // Paths rather than URL values, because two URLs naming one directory
    // differ by a trailing slash, and path() percent encodes the space in the
    // folder name.
    let directory = ModelStore.directory.path(percentEncoded: false)

    #expect(location.lastPathComponent == ModelCatalog.recommended.id)
    #expect(location.path(percentEncoded: false).hasPrefix(directory))
    #expect(directory.contains("Application Support"))
}

/// The store reads a model in blocks because it does not fit comfortably in
/// memory. The expected value is computed here in one piece rather than written
/// down, so the two ways of hashing are compared rather than a constant.
@Test func hashesAFileInBlocks() async throws {
    let file = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/formats/clip.wav")

    let wholeFile = SHA256.hash(data: try Data(contentsOf: file))
        .map { String(format: "%02x", $0) }
        .joined()

    #expect(try await ModelStore.sha256(of: file) == wholeFile)
}

/// The download path is only proven by running it, but a suite that reaches
/// the network fails without one. This test is therefore asked for
/// explicitly, with POLYCOP_NETWORK_TESTS=1, and uses the smallest pinned
/// file there is.
@Test(.enabled(if: ProcessInfo.processInfo.environment["POLYCOP_NETWORK_TESTS"] == "1"))
func downloadsAndVerifiesAPinnedFile() async throws {
    let silero = Model(
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
    defer { try? ModelStore.remove(silero) }

    let reported = OSAllocatedUnfairLock(initialState: 0.0)
    let file = try await ModelDownloader.download(silero) { progress in
        reported.withLock { $0 = max($0, progress) }
    }

    #expect(try await ModelStore.sha256(of: file) == silero.sha256)
    #expect(ModelStore.isInstalled(silero))
    #expect(reported.withLock { $0 } > 0)
}

@Test func aMissingModelIsNotInstalled() {
    let absent = Model(
        id: "ggml-not-a-real-model.bin",
        name: "Absent",
        detail: "Never downloaded",
        bytes: 1,
        peakBytes: 2,
        sha256: String(repeating: "0", count: 64),
        license: "MIT",
        repository: "example/example",
        commit: String(repeating: "0", count: 40),
        file: "ggml-model.bin"
    )

    #expect(!ModelStore.isInstalled(absent))
}

/// The memory check has to fire before whisper.cpp is asked to open the file,
/// otherwise a Mac short of memory gets the message meant for a damaged model.
@Test(.enabled(if: Memory.recommendedBudget > 0))
func aModelTooLargeForThisMacIsRefusedBeforeLoading() async {
    let ceiling = Memory.recommendedBudget
    let enormous = Model(
        id: "ggml-enormous.bin",
        name: "Enormous",
        detail: "Larger than any Mac",
        bytes: ceiling * 2,
        peakBytes: ceiling * 2,
        sha256: String(repeating: "0", count: 64),
        license: "MIT",
        repository: "example/example",
        commit: String(repeating: "0", count: 40),
        file: "ggml-model.bin"
    )

    #expect(!Memory.isLikelyToFit(enormous))

    // A file that exists, so the refusal can only come from the memory check.
    let present = URL(filePath: #filePath)
    await #expect {
        _ = try await WhisperEngine.load(model: present, expecting: enormous)
    } throws: { error in
        guard case TranscriptionError.notEnoughMemory(let needed, let budget) = error else {
            return false
        }
        return needed == enormous.peakBytes && budget == ceiling
    }
}

@Test(arguments: [
    (peak: Int64(4_000_000_000), budget: Int64(5_000_000_000), expected: true),
    (peak: Int64(5_000_000_000), budget: Int64(5_000_000_000), expected: false),
    (peak: Int64(6_000_000_000), budget: Int64(5_000_000_000), expected: false),
    (peak: Int64(6_000_000_000), budget: Int64(8_000_000_000), expected: true),
    (peak: Int64(6_000_000_000), budget: Int64(0), expected: true),
])
func modelMemoryFitsTheBudget(peak: Int64, budget: Int64, expected: Bool) {
    #expect(Memory.fits(peak, budget: budget) == expected)
}

// MARK: Verified imports

@Test func importingAcceptsOnlyKnownBytesAndUsesTheCatalogueName() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appending(path: "renamed.bin")
    let data = Data(repeating: 3, count: 2048)
    try data.write(to: source)
    let model = Model(
        id: "known.bin", name: "Test", detail: "Synthetic", bytes: Int64(data.count),
        peakBytes: 4096, sha256: Transcript.digest(data), license: "MIT",
        repository: "example/test", commit: String(repeating: "0", count: 40), file: "known.bin")
    let store = folder.appending(path: "Models")
    #expect(try await ModelStore.install(source, in: store, catalogue: [model]) == model)
    #expect(try Data(contentsOf: store.appending(path: model.id)) == data)
    // A second verified import replaces the same model without creating duplicates.
    _ = try await ModelStore.install(source, in: store, catalogue: [model])
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.path) == [model.id])
    try Data(repeating: 4, count: data.count).write(to: source)
    await #expect(throws: ModelStore.ImportError.unrecognized) {
        _ = try await ModelStore.install(source, in: store, catalogue: [model])
    }
    #expect(try Data(contentsOf: store.appending(path: model.id)) == data)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.path) == [model.id])
}

@Test func unknownModelIsRefusedWithoutCallingTheNativeParser() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appending(path: "unknown-ftype.bin")
    var header: [Int32] = [0x6767_6d6c, 51865, 1500, 384, 6, 4, 448, 384, 6, 4, 80, 999]
    try header.withUnsafeMutableBytes { try Data($0).write(to: source) }
    await #expect(throws: ModelStore.ImportError.unrecognized) {
        _ = try await ModelStore.install(source, in: folder.appending(path: "Models"))
    }
}

@Test func aCancelledImportNeverPublishesAFile() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await ModelStore.install(URL(filePath: #filePath), in: folder)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: folder.path))
}

@Test func verificationChecksTheFileLoadedAndDetectsAReplacement() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "test.gguf")
    let data = Data("verified model".utf8)
    let model = Model(
        id: "test.gguf", name: "Test", detail: "", bytes: Int64(data.count),
        peakBytes: 4096, sha256: Transcript.digest(data), license: "MIT",
        repository: "test/model", commit: "test", file: "test.gguf")
    try data.write(to: file)
    try await ModelStore.verify(model, at: file)
    try Data(repeating: 0, count: data.count).write(to: file)
    await #expect(throws: ModelStore.ImportError.self) {
        try await ModelStore.verify(model, at: file)
    }
}
