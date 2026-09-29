// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import Testing

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
    let reference = try await AudioDecoder.samples(of: fixture("clip.wav"))
    let samples = try await AudioDecoder.samples(of: fixture(name))

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

@Test func reportsAFileItCannotRead() async throws {
    let text = URL.temporaryDirectory.appending(path: "not-audio-\(UUID().uuidString).txt")
    try "ceci n'est pas un enregistrement".write(to: text, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: text) }

    await #expect(throws: AudioError.self) {
        _ = try await AudioDecoder.samples(of: text)
    }
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

/// ffmpeg can log every frame of a damaged file while writing no sample for
/// a long time, so the log is capped on a timer, not as samples arrive.
@Test func theErrorLogIsCappedWhileNoSampleArrives() async throws {
    let log = URL.temporaryDirectory.appending(path: "log-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
    defer { try? FileManager.default.removeItem(at: log) }
    let handle = try FileHandle(forWritingTo: log)
    defer { try? handle.close() }
    try handle.write(contentsOf: Data(count: AudioDecoder.logLimit + 1))

    let stopCapping = AudioDecoder.capping(handle, every: 0.01)
    defer { stopCapping() }
    var waited = 0
    while try handle.offset() > 0, waited < 500 {
        try await Task.sleep(for: .milliseconds(10))
        waited += 1
    }
    #expect(try handle.offset() == 0)
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
    await #expect(throws: AudioError.self) {
        _ = try await AudioDecoder.samples(of: fixture("clip.flac"), maximumDuration: 0.1)
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
