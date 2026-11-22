// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import Testing
import os

@testable import Polycop

/// Every container the app accepts, written from one spoken sentence by
/// `Tools/fixtures.sh`. The audio is identical in all of them, so a difference
/// between two of them comes from the codec and from nothing else.
private let formats = [
    "clip.aac", "clip.aiff", "clip.caf", "clip.flac", "clip.m4a", "clip.mkv",
    "clip.mov", "clip.mp3", "clip.mp4", "clip.ogg", "clip.opus", "clip.wav",
    "clip.webm", "clip.wma",
]

private let fixtures = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/formats")

private func fixture(_ name: String) -> URL {
    fixtures.appending(path: name)
}

private func duration(_ samples: [Float]) -> TimeInterval {
    TimeInterval(samples.count) / TimeInterval(AudioDecoder.sampleRate)
}

/// Calls `AudioDecoder.samples(of:)` and records spawn diagnostics when
/// `Process.run()` throws POSIX `EFAULT` (issue #152) before rethrowing.
private func decodeSamples(of recording: URL) async throws -> [Float] {
    do {
        return try await AudioDecoder.samples(of: recording)
    } catch {
        reportSpawnFaultIfNeeded(error, recording: recording)
        throw error
    }
}

private func reportSpawnFaultIfNeeded(_ error: any Error, recording: URL) {
    let nsError = error as NSError
    guard nsError.domain == NSPOSIXErrorDomain,
        nsError.code == Int(POSIXErrorCode.EFAULT.rawValue)
    else { return }
    let environment = ProcessInfo.processInfo.environment
    let environmentBytes = environment.reduce(0) { total, pair in
        total + pair.key.utf8.count + pair.value.utf8.count + 2
    }
    let helperPath = AudioDecoder.helper.path(percentEncoded: false)
    let recordingPath = recording.path(percentEncoded: false)
    let dyldLibraries = environment["DYLD_INSERT_LIBRARIES"] ?? "(none)"
    Issue.record(
        """
        Process.run threw EFAULT (#152) for \(recording.lastPathComponent): \
        helperBytes=\(helperPath.utf8.count), \
        helperExecutable=\(FileManager.default.isExecutableFile(atPath: helperPath)), \
        recordingBytes=\(recordingPath.utf8.count), \
        envCount=\(environment.count), \
        envBytes=\(environmentBytes), \
        dyldInsertLibraries=\(dyldLibraries)
        """
    )
}

private func writeSparseLongWave(to url: URL) throws {
    let sampleRate: UInt32 = 96_000
    let bytesPerSample: UInt16 = 2
    let dataSize: UInt32 = 3 * 3600 * sampleRate * UInt32(bytesPerSample)
    var header = Data()
    header.append(contentsOf: "RIFF".utf8)
    appendLittleEndian(36 + dataSize, to: &header)
    header.append(contentsOf: "WAVEfmt ".utf8)
    appendLittleEndian(UInt32(16), to: &header)
    appendLittleEndian(UInt16(1), to: &header)
    appendLittleEndian(UInt16(1), to: &header)
    appendLittleEndian(sampleRate, to: &header)
    appendLittleEndian(sampleRate * UInt32(bytesPerSample), to: &header)
    appendLittleEndian(bytesPerSample, to: &header)
    appendLittleEndian(UInt16(16), to: &header)
    header.append(contentsOf: "data".utf8)
    appendLittleEndian(dataSize, to: &header)

    FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: header)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(header.count) + UInt64(dataSize))
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    for shift in stride(from: 0, to: T.bitWidth, by: 8) {
        data.append(UInt8(truncatingIfNeeded: value >> shift))
    }
}

private func temporaryLogNames() -> Set<String> {
    let entries =
        (try? FileManager.default.contentsOfDirectory(
            atPath: URL.temporaryDirectory.path(percentEncoded: false)
        )) ?? []
    return Set(entries.filter { $0.hasPrefix("polycop-") && $0.hasSuffix(".log") })
}

/// The app carries its own decoder, so the user never installs anything.
@Test func theHelperShipsInsideTheApplication() {
    #expect(FileManager.default.isExecutableFile(atPath: AudioDecoder.helper.path))
}

/// Codecs round-trip audio at slightly different lengths (padding, downmixing,
/// container edit lists), so the tolerance is set above the largest drift
/// found across the fixtures.
private let tolerance: TimeInterval = 0.08

@Test(arguments: formats)
func decodesEveryFormat(_ name: String) async throws {
    let reference = try await decodeSamples(of: fixture("clip.wav"))
    let samples = try await decodeSamples(of: fixture(name))

    #expect(!samples.isEmpty)
    // Speech, not a silent file that happens to have the right length.
    #expect(samples.contains { abs($0) > 0.01 })
    #expect(abs(duration(samples) - duration(reference)) < tolerance)
}

/// A lecture downloaded from a video service carries a picture the app ignores.
@Test func ignoresTheVideoTrack() async throws {
    let withVideo = try await AudioDecoder.samples(of: fixture("clip-video.mkv"))
    let audioOnly = try await AudioDecoder.samples(of: fixture("clip.mkv"))

    #expect(!withVideo.isEmpty)
    #expect(abs(duration(withVideo) - duration(audioOnly)) < 0.05)
}

/// A video-only recording has no audio stream; ffmpeg's diagnostic must map to
/// `noAudioTrack` rather than `unreadable` for both decoding and replay copies.
@Test func reportsAVideoOnlyRecordingAsHavingNoAudioTrack() async throws {
    let silent = fixture("clip-silent.mp4")

    do {
        _ = try await decodeSamples(of: silent)
        Issue.record("A video-only file was decoded as audio")
    } catch AudioError.noAudioTrack(silent) {
    } catch {
        Issue.record("Expected noAudioTrack, got \(error)")
    }

    let copy = URL.temporaryDirectory.appending(path: "silent-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: copy) }
    do {
        try await AudioDecoder.writePlayableCopy(of: silent, to: copy)
        Issue.record("A video-only file produced a playable copy")
    } catch AudioError.noAudioTrack(silent) {
    } catch {
        reportSpawnFaultIfNeeded(error, recording: silent)
        Issue.record("Expected noAudioTrack for playable copy, got \(error)")
    }
}

@Test func reportsAFileItCannotRead() async throws {
    let text = URL.temporaryDirectory.appending(path: "not-audio-\(UUID().uuidString).txt")
    try "ceci n'est pas un enregistrement".write(to: text, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: text) }
    let before = temporaryLogNames()

    do {
        _ = try await decodeSamples(of: text)
        Issue.record("A text file was decoded as audio")
    } catch AudioError.unreadable(text, let detail) {
        #expect(!detail.isEmpty)
    } catch {
        Issue.record("Expected unreadable with diagnostic detail, got \(error)")
    }

    #expect(temporaryLogNames().subtracting(before).isEmpty)
}

/// Only a file that is not there has moved. One the app may not read is
/// reported as unreadable, so the user is not told to look for it.
@Test func aRecordingInAFolderWithoutAccessIsUnreadableNotMissing() async throws {
    let folder = URL.temporaryDirectory.appending(path: "locked-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let recording = folder.appending(path: "clip.wav")
    try Data().write(to: recording)
    let path = folder.path(percentEncoded: false)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        try? FileManager.default.removeItem(at: folder)
    }

    do {
        _ = try await AudioDecoder.samples(of: recording)
        Issue.record("A file in a folder without access was decoded")
    } catch AudioError.unreadable {
    } catch {
        Issue.record("Expected unreadable, got \(error)")
    }
}

/// Draining a stderr pipe keeps only the last `logTail` bytes in memory without
/// blocking when a helper writes past macOS's 64 KB pipe buffer.
@Test func errorTailKeepsOnlyTheLastBytesWithoutBlocking() throws {
    let pipe = Pipe()
    let tail = AudioDecoder.ErrorTail.drain(pipe.fileHandleForReading)
    let writer = pipe.fileHandleForWriting

    let prefix = Data(repeating: UInt8(ascii: "0"), count: 70_000)
    let marker = Data("tail-end\n".utf8)
    let middle = Data(repeating: UInt8(ascii: "1"), count: AudioDecoder.logTail - marker.count)
    let payload = prefix + middle + marker

    var offset = 0
    for step in [1_000, 17_000, 3_333, 48_667, 3_000, 3_000] {
        let end = min(offset + step, payload.count)
        if offset < end {
            try writer.write(contentsOf: payload[offset..<end])
            offset = end
        }
    }
    if offset < payload.count {
        try writer.write(contentsOf: payload[offset...])
    }
    try writer.close()

    let kept = tail.finish()
    let expected = String(decoding: payload.suffix(AudioDecoder.logTail), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(kept == expected)
    #expect(!kept.contains("0"))
    #expect(kept.hasSuffix("tail-end"))
    #expect(kept.utf8.count == AudioDecoder.logTail - 1)
}

/// Covers the empty-stream and first-wrap ring-buffer transitions on `ErrorTail`.
@Test func errorTailHandlesEmptyAndFirstWrapStreams() throws {
    let emptyPipe = Pipe()
    let emptyTail = AudioDecoder.ErrorTail.drain(emptyPipe.fileHandleForReading)
    try emptyPipe.fileHandleForWriting.close()
    #expect(emptyTail.finish().isEmpty)

    let pipe = Pipe()
    let tail = AudioDecoder.ErrorTail.drain(pipe.fileHandleForReading)
    let writer = pipe.fileHandleForWriting
    let first = Data(repeating: UInt8(ascii: "x"), count: 5_000)
    let second = Data(repeating: UInt8(ascii: "y"), count: 5_000)
    try writer.write(contentsOf: first)
    try writer.write(contentsOf: second)
    try writer.close()

    let kept = tail.finish()
    let expected =
        String(repeating: "x", count: AudioDecoder.logTail - 5_000)
        + String(repeating: "y", count: 5_000)
    #expect(kept == expected)
}

/// A stop that arrives before ffmpeg starts must not be lost, or such a decode
/// runs to completion and returns every sample.
@Test func aDecodeCancelledBeforeItStartsDoesNotRun() async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await AudioDecoder.samples(of: fixture("clip.wav"))
    }
    let result = await task.result

    #expect(throws: CancellationError.self) { try result.get() }
}

/// Cancelling a task once ffmpeg is actively writing stops the helper promptly
/// instead of letting it finish decoding a multi-hour recording.
@Test func cancellingAnActiveDecodeStopsFfmpeg() async throws {
    let recording = URL.temporaryDirectory.appending(path: "sparse-\(UUID().uuidString).wav")
    let copy = URL.temporaryDirectory.appending(path: "copy-\(UUID().uuidString).wav")
    defer {
        try? FileManager.default.removeItem(at: recording)
        try? FileManager.default.removeItem(at: copy)
    }
    try writeSparseLongWave(to: recording)

    let finished = OSAllocatedUnfairLock(initialState: false)
    let task = Task {
        defer { finished.withLock { $0 = true } }
        try await AudioDecoder.writePlayableCopy(of: recording, to: copy)
    }

    let copyPath = copy.path(percentEncoded: false)
    let deadline = ContinuousClock.now + .seconds(30)
    var started = false
    while ContinuousClock.now < deadline, !finished.withLock({ $0 }) {
        let size = (try? FileManager.default.attributesOfItem(atPath: copyPath)[.size] as? Int) ?? 0
        if size > 0 {
            started = true
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(started)
    task.cancel()

    do {
        try await task.value
        Issue.record("Cancelled ffmpeg decode completed instead of throwing CancellationError")
    } catch is CancellationError {
    } catch {
        reportSpawnFaultIfNeeded(error, recording: recording)
        Issue.record("Expected CancellationError, got \(error)")
    }

    let written =
        (try? FileManager.default.attributesOfItem(atPath: copyPath)[.size] as? Int) ?? 0
    let fullSize = 3 * 3600 * AudioDecoder.sampleRate * MemoryLayout<Int16>.size
    #expect(written < fullSize)
}

// MARK: Replay

/// Whatever the format, replay gets a file AVFoundation plays, either the
/// recording itself or a decoded copy lasting exactly as long as the decoded
/// audio.
@Test(arguments: formats + ["clip-video.mkv"])
func everyFormatCanBeReplayed(_ name: String) async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let recording = fixture(name)

    let file = try await Player.playableFile(for: recording, in: folder)

    #expect(try await AVURLAsset(url: file).load(.isPlayable))
    // Matroska is not played on macOS 26, so this case runs the copy.
    if name.hasSuffix(".mkv") {
        #expect(file != recording)
    }
    if file != recording {
        let copied = try await AVURLAsset(url: file).load(.duration).seconds
        let decoded = duration(try await AudioDecoder.samples(of: recording))
        #expect(abs(copied - decoded) < 0.01)
    }
}

@Test func aMovedRecordingIsReportedMissing() async {
    let gone = URL.temporaryDirectory.appending(path: "gone-\(UUID().uuidString).m4a")

    await #expect(throws: PlaybackError.self) {
        _ = try await Player.playableFile(for: gone)
    }
}

@Test func decodingStopsAtThePCMLimit() async {
    await #expect(throws: AudioError.tooLong) {
        _ = try await AudioDecoder.samples(of: fixture("clip.flac"), maximumDuration: 0.1)
    }
}

@Test func writePlayableCopyRejectsNonRegularFiles() async throws {
    let directory = URL.temporaryDirectory.appending(path: "dir-\(UUID().uuidString)")
    let copy = URL.temporaryDirectory.appending(path: "copy-\(UUID().uuidString).wav")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: copy)
    }

    do {
        try await AudioDecoder.writePlayableCopy(of: directory, to: copy)
        Issue.record("A directory was accepted by writePlayableCopy")
    } catch AudioError.unreadable(directory, _) {
    } catch {
        Issue.record("Expected unreadable for directory, got \(error)")
    }
}

@Test func decodingRejectsRemoteURLsBeforeStartingAProcess() async throws {
    let remote = try #require(URL(string: "https://example.com/audio.wav"))
    await #expect(throws: AudioError.self) {
        _ = try await AudioDecoder.samples(of: remote)
    }
}

@Test func aCancelledReplayDoesNotLeaveACopy() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await Player.playableFile(for: fixture("clip.mkv"), in: folder)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: folder.path))
}
