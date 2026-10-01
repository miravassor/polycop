// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import Network
import Testing
import os

@testable import Polycop

/// Serves one file over HTTP on the loopback interface, with ranges and a
/// validator as Hugging Face's CDN does, so downloads run without a network.
private nonisolated final class LoopbackServer: Sendable {
    /// What to do with a request, chosen by the test.
    enum Answer: Sendable {
        /// The file, or the part a range asks for.
        case file
        /// A status and nothing else.
        case status(Int)
        /// The start of the file, then nothing until the client lets go.
        case stall(after: Int)
    }

    struct Request: Sendable {
        /// Header names in lower case.
        let headers: [String: String]
    }

    private let body: Data
    private let answer: @Sendable (Request) -> Answer
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let state = OSAllocatedUnfairLock(
        initialState: (requests: [Request](), connections: [NWConnection]()))
    private static let validator = "\"polycop-test\""

    var requests: [Request] { state.withLock { $0.requests } }

    init(body: Data, answer: @escaping @Sendable (Request) -> Answer) throws {
        self.body = body
        self.answer = answer
        let parameters = NWParameters.tcp
        // Loopback only, so the firewall never asks about it.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns the address of the file.
    func start() async throws -> URL {
        let ready = AsyncStream<NWListener.State>.makeStream()
        listener.stateUpdateHandler = { ready.continuation.yield($0) }
        listener.newConnectionHandler = { [self] connection in
            state.withLock { $0.connections.append(connection) }
            connection.start(queue: queue)
            receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)
        for await state in ready.stream {
            if case .failed(let error) = state { throw error }
            if case .ready = state, let port = listener.port {
                return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)/model.bin"))
            }
        }
        throw CancellationError()
    }

    func stop() {
        listener.cancel()
        for connection in state.withLock({ $0.connections }) { connection.cancel() }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [self] data, _, isComplete, error in
            let buffer = buffer + (data ?? Data())
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                respond(
                    to: Self.request(String(decoding: buffer[..<end.lowerBound], as: UTF8.self)),
                    on: connection)
            } else if !isComplete, error == nil {
                receive(on: connection, buffer: buffer)
            }
        }
    }

    private static func request(_ head: String) -> Request {
        var headers: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Request(headers: headers)
    }

    private func respond(to request: Request, on connection: NWConnection) {
        state.withLock { $0.requests.append(request) }
        switch answer(request) {
        case .status(let code):
            send(
                "HTTP/1.1 \(code) Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                on: connection)
        case .stall(let count):
            let head = header(status: 200, from: 0)
            connection.send(content: Data(head.utf8) + body.prefix(count), completion: .idempotent)
        case .file:
            var start = 0
            if let range = request.headers["range"], range.hasPrefix("bytes="),
                request.headers["if-range"].map({ $0 == Self.validator }) ?? true,
                let first = Int(range.dropFirst(6).prefix { $0 != "-" })
            {
                start = first
            }
            let head = header(status: start > 0 ? 206 : 200, from: start)
            connection.send(
                content: Data(head.utf8) + body[start...], isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func header(status: Int, from start: Int) -> String {
        var lines = [
            "HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : "OK")",
            "Content-Type: application/octet-stream",
            "Content-Length: \(body.count - start)",
            "Accept-Ranges: bytes",
            "ETag: \(Self.validator)",
            "Last-Modified: Wed, 01 Oct 2026 08:00:00 GMT",
            "Connection: close",
        ]
        if status == 206 {
            lines.append("Content-Range: bytes \(start)-\(body.count - 1)/\(body.count)")
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private func send(_ text: String, on connection: NWConnection) {
        connection.send(
            content: Data(text.utf8), isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Bytes that are not all alike, so a part in the wrong place changes the hash.
private let body = Data((0..<262_144).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })

private func model(of data: Data, bytes: Int? = nil) -> Model {
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return Model(
        id: "test-model.bin", name: "Test", detail: "", bytes: Int64(bytes ?? data.count),
        peakBytes: 1, sha256: hash, license: "MIT", repository: "example/models",
        commit: String(repeating: "0", count: 40), file: "model.bin")
}

private func temporaryFolder() -> URL {
    URL.temporaryDirectory.appending(path: UUID().uuidString)
}

/// What the folder holds, apart from an installed model.
private func leftovers(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))
        ?? []).filter { $0 != "test-model.bin" }
}

private func fails(_ operation: () async throws -> URL, with expected: (DownloadError) -> Bool)
    async -> Bool
{
    do {
        _ = try await operation()
        return false
    } catch let error as DownloadError {
        return expected(error)
    } catch {
        return false
    }
}

@Test func downloadsIntoTheFolderGivenWithFixedHeaders() async throws {
    let server = try LoopbackServer(body: body) { _ in .file }
    defer { server.stop() }
    let url = try await server.start()
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let file = try await ModelDownloader.download(model(of: body), from: url, in: folder)

    #expect(try Data(contentsOf: file) == body)
    #expect(leftovers(in: folder).isEmpty)
    #expect(server.requests.first?.headers["user-agent"] == "Polycop")
    #expect(server.requests.first?.headers["accept-language"] == "en")
    #expect(server.requests.first?.headers["cookie"] == nil)
}

@Test func aRefusedOrWrongDownloadLeavesNothing() async throws {
    let refusing = try LoopbackServer(body: body) { _ in .status(403) }
    defer { refusing.stop() }
    let refused = try await refusing.start()
    let serving = try LoopbackServer(body: body) { _ in .file }
    defer { serving.stop() }
    let served = try await serving.start()
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    #expect(
        await fails({
            try await ModelDownloader.download(model(of: body), from: refused, in: folder)
        }) {
            if case .httpFailure(403) = $0 { true } else { false }
        })
    #expect(
        await fails({
            try await ModelDownloader.download(
                model(of: Data("other".utf8) + body), from: served, in: folder)
        }) {
            if case .checksumMismatch = $0 { true } else { false }
        })
    #expect(
        await fails({
            try await ModelDownloader.download(
                model(of: body, bytes: 1000), from: served, in: folder)
        }) {
            if case .tooLarge = $0 { true } else { false }
        })
    #expect(leftovers(in: folder).isEmpty)
}

/// Cancel and Quit stop the download with the bytes kept, and the next
/// attempt asks only for the rest.
@Test(.timeLimit(.minutes(1)))
func aStoppedDownloadContinuesWhereItStopped() async throws {
    let isFirst = OSAllocatedUnfairLock(initialState: true)
    let server = try LoopbackServer(body: body) { _ in
        isFirst.withLock { first in
            defer { first = false }
            return first ? .stall(after: body.count / 2) : .file
        }
    }
    defer { server.stop() }
    let url = try await server.start()
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = model(of: body)

    try await stopDownloading(model, from: url, in: folder)
    #expect(
        FileManager.default.fileExists(
            atPath: ModelStore.resumeFile(of: model, in: folder).path(percentEncoded: false)))

    let file = try await ModelDownloader.download(model, from: url, in: folder)

    #expect(try Data(contentsOf: file) == body)
    #expect(server.requests.last?.headers["range"]?.hasPrefix("bytes=") == true)
    #expect(leftovers(in: folder).isEmpty)
}

/// Resume data replays a request the server may no longer accept, such as an
/// expired signed redirect. The download then starts over from the address.
@Test(.timeLimit(.minutes(1)))
func aRefusedResumeStartsOver() async throws {
    let isFirst = OSAllocatedUnfairLock(initialState: true)
    let server = try LoopbackServer(body: body) { request in
        let first = isFirst.withLock { first in
            defer { first = false }
            return first
        }
        if first { return .stall(after: body.count / 2) }
        return request.headers["range"] == nil ? .file : .status(403)
    }
    defer { server.stop() }
    let url = try await server.start()
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = model(of: body)

    try await stopDownloading(model, from: url, in: folder)
    let file = try await ModelDownloader.download(model, from: url, in: folder)

    #expect(try Data(contentsOf: file) == body)
    #expect(server.requests.last?.headers["range"] == nil)
    #expect(leftovers(in: folder).isEmpty)
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
