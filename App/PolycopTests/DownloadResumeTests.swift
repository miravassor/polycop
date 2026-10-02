// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import os

@testable import Polycop

// Stopped, resumed and interrupted downloads, served by `LoopbackServer`.

/// Cancel and Quit stop the download with the bytes kept, and the next
/// attempt asks only for the rest.
@Test(.timeLimit(.minutes(1)))
func aStoppedDownloadContinuesWhereItStopped() async throws {
    let isFirst = OSAllocatedUnfairLock(initialState: true)
    let server = try LoopbackServer(body: servedBody) { _ in
        isFirst.withLock { first in
            defer { first = false }
            return first ? .stall(after: servedBody.count / 2) : .file
        }
    }
    defer { server.stop() }
    let url = try await server.start()
    let folder = downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = servedModel(of: servedBody)

    try await stopDownloading(model, from: url, in: folder)
    #expect(
        FileManager.default.fileExists(
            atPath: ModelStore.resumeFile(of: model, in: folder).path(percentEncoded: false)))

    let file = try await ModelDownloader.download(model, from: url, in: folder)

    #expect(try Data(contentsOf: file) == servedBody)
    #expect(server.requests.last?.headers["range"]?.hasPrefix("bytes=") == true)
    #expect(downloadLeftovers(in: folder).isEmpty)
}

/// Resume data replays a request the server may no longer accept, such as an
/// expired signed redirect. The download then starts over from the address.
@Test(.timeLimit(.minutes(1)))
func aRefusedResumeStartsOver() async throws {
    let isFirst = OSAllocatedUnfairLock(initialState: true)
    let server = try LoopbackServer(body: servedBody) { request in
        let first = isFirst.withLock { first in
            defer { first = false }
            return first
        }
        if first { return .stall(after: servedBody.count / 2) }
        return request.headers["range"] == nil ? .file : .status(403)
    }
    defer { server.stop() }
    let url = try await server.start()
    let folder = downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = servedModel(of: servedBody)

    try await stopDownloading(model, from: url, in: folder)
    let file = try await ModelDownloader.download(model, from: url, in: folder)

    #expect(try Data(contentsOf: file) == servedBody)
    #expect(server.requests.last?.headers["range"] == nil)
    #expect(downloadLeftovers(in: folder).isEmpty)
}

/// macOS deletes temporary files left untouched for days, the partial file
/// resume data points to among them. The download then starts over once.
@Test(.timeLimit(.minutes(1)))
func aResumeWhosePartialFileIsGoneStartsOver() async throws {
    let isFirst = OSAllocatedUnfairLock(initialState: true)
    let server = try LoopbackServer(body: servedBody) { _ in
        isFirst.withLock { first in
            defer { first = false }
            return first ? .stall(after: servedBody.count / 2) : .file
        }
    }
    defer { server.stop() }
    let url = try await server.start()
    let folder = downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = servedModel(of: servedBody)

    try await stopDownloading(model, from: url, in: folder)
    let resumeData = try Data(contentsOf: ModelStore.resumeFile(of: model, in: folder))
    let info = try #require(
        PropertyListSerialization.propertyList(from: resumeData, format: nil) as? [String: Any])
    // A keyed archive: the partial file's name is one of its strings.
    let strings = (info["$objects"] as? [Any] ?? []).compactMap { $0 as? String }
    let partial = try #require(strings.first { $0.contains("CFNetworkDownload_") })
    let place =
        partial.hasPrefix("/")
        ? URL(filePath: partial) : FileManager.default.temporaryDirectory.appending(path: partial)
    try FileManager.default.removeItem(at: place)

    let file = try await ModelDownloader.download(model, from: url, in: folder)

    #expect(try Data(contentsOf: file) == servedBody)
    #expect(server.requests.last?.headers["range"] == nil)
    #expect(downloadLeftovers(in: folder).isEmpty)
}

/// A stop while the whole file is being checked keeps it: the next attempt
/// checks it again and asks the server for nothing.
@Test(.timeLimit(.minutes(1)))
func aStopDuringTheCheckKeepsTheFile() async throws {
    let server = try LoopbackServer(body: servedBody) { _ in .file }
    defer { server.stop() }
    let url = try await server.start()
    let folder = downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = servedModel(of: servedBody)

    let checking = AsyncStream<Void>.makeStream()
    let download = Task {
        try await ModelDownloader.download(model, from: url, in: folder) { _ in
        } digest: { _ in
            checking.continuation.yield()
            try await Task.sleep(for: .seconds(60))
            return ""
        }
    }
    for await _ in checking.stream { break }
    download.cancel()
    await #expect(throws: (any Error).self) { try await download.value }
    #expect(
        FileManager.default.fileExists(
            atPath: ModelStore.receivedFile(of: model, in: folder).path(percentEncoded: false)))
    let asked = server.requests.count

    let file = try await ModelDownloader.download(model, from: url, in: folder)

    #expect(try Data(contentsOf: file) == servedBody)
    #expect(server.requests.count == asked)
    #expect(downloadLeftovers(in: folder).isEmpty)
}

/// A kept file that does not match is removed and the model downloaded again.
@Test(.timeLimit(.minutes(1)))
func aKeptFileThatDoesNotMatchIsDownloadedAgain() async throws {
    let server = try LoopbackServer(body: servedBody) { _ in .file }
    defer { server.stop() }
    let url = try await server.start()
    let folder = downloadFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = servedModel(of: servedBody)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(repeating: 0, count: servedBody.count).write(
        to: ModelStore.receivedFile(of: model, in: folder))

    let file = try await ModelDownloader.download(model, from: url, in: folder)

    #expect(try Data(contentsOf: file) == servedBody)
    #expect(server.requests.count == 1)
    #expect(downloadLeftovers(in: folder).isEmpty)
}

/// Starts a download, waits for its first bytes, then stops it as Cancel does.
private func stopDownloading(_ model: Model, from url: URL, in folder: URL) async throws {
    let progressed = AsyncStream<Void>.makeStream()
    let download = Task {
        try await ModelDownloader.download(model, from: url, in: folder) { _ in
            progressed.continuation.yield()
        }
    }
    for await _ in progressed.stream { break }
    download.cancel()
    await #expect(throws: (any Error).self) { try await download.value }
}
