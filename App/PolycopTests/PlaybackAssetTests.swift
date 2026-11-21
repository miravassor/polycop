// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import Testing

@testable import Polycop

private let formatFixtures = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/formats")

private func quickTimeBox(_ type: String, payload: Data) -> Data {
    var box = Data()
    withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian) { box.append(contentsOf: $0) }
    box.append(contentsOf: type.utf8)
    box.append(payload)
    return box
}

/// A minimal QuickTime reference movie (`rmra`/`rmda`/`rdrf`) pointing to a
/// separate local media file outside the container.
private func referenceMovie(pointingTo target: URL) -> Data {
    var rdrf = Data([0, 0, 0, 0])
    rdrf.append(contentsOf: "url ".utf8)
    var urlBytes = Data(target.absoluteString.utf8)
    urlBytes.append(0)
    withUnsafeBytes(of: UInt32(urlBytes.count).bigEndian) { rdrf.append(contentsOf: $0) }
    rdrf.append(urlBytes)
    let moov = quickTimeBox(
        "moov",
        payload: quickTimeBox(
            "rmra",
            payload: quickTimeBox("rmda", payload: quickTimeBox("rdrf", payload: rdrf))))
    var ftyp = Data("qt  ".utf8)
    ftyp.append(contentsOf: [0, 0, 0, 0])
    ftyp.append(contentsOf: "qt  ".utf8)
    return quickTimeBox("ftyp", payload: ftyp) + moov
}

private func isForbiddenReferenceError(_ error: any Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == AVFoundationErrorDomain
        && nsError.code == AVError.referenceForbiddenByReferencePolicy.rawValue
}

@MainActor
private func playAndCollectCopy(of recording: URL, on player: Player) async throws
    -> Player.KeptCopy
{
    player.play(recording, from: 0)
    for _ in 0..<100 where !(player.isOpen && player.duration > 0) {
        try await Task.sleep(for: .milliseconds(50))
    }
    try #require(player.isOpen)
    player.stop()
    return try #require(player.keptCopy)
}

@Test func assetForbidsExternalReferencesAndRespectsPreciseTiming() async throws {
    let mp3 = formatFixtures.appending(path: "clip.mp3")

    let standard = try Player.asset(for: mp3)
    #expect(standard.referenceRestrictions == .forbidAll)
    #expect(try await !standard.load(.providesPreciseDurationAndTiming))

    let precise = try Player.asset(for: mp3, preciseTiming: true)
    #expect(precise.referenceRestrictions == .forbidAll)
    #expect(try await precise.load(.providesPreciseDurationAndTiming))
}

@Test func assetAndVideoHelpersRejectRemoteURLs() async throws {
    let remote = try #require(URL(string: "https://example.com/lecture.mp4"))
    let copies = URL.temporaryDirectory.appending(path: "remote-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: copies) }

    do {
        _ = try Player.asset(for: remote)
        Issue.record("Expected asset(for:) to reject remote URL")
    } catch PlaybackError.unplayable {
    } catch {
        Issue.record("Expected PlaybackError.unplayable, got \(error)")
    }

    #expect(await Player.pictureSize(of: remote) == nil)

    do {
        _ = try await Player.frame(of: remote, at: 0)
        Issue.record("Expected frame(of:at:) to reject remote URL")
    } catch PlaybackError.unplayable {
    } catch {
        Issue.record("Expected PlaybackError.unplayable, got \(error)")
    }

    do {
        _ = try await Player.playableFile(for: remote, in: copies)
        Issue.record("Expected playableFile(for:in:) to reject remote URL")
    } catch PlaybackError.unplayable {
    } catch {
        Issue.record("Expected PlaybackError.unplayable, got \(error)")
    }
    #expect(!FileManager.default.fileExists(atPath: copies.path(percentEncoded: false)))
}

@Test func assetRejectsExternalLocalReferences() async throws {
    let video = formatFixtures.appending(path: "clip-video.mp4")
    let reference = URL.temporaryDirectory.appending(path: "ref-\(UUID().uuidString).mov")
    let copies = URL.temporaryDirectory.appending(path: "ref-copies-\(UUID().uuidString)")
    try referenceMovie(pointingTo: video).write(to: reference)
    defer {
        try? FileManager.default.removeItem(at: reference)
        try? FileManager.default.removeItem(at: copies)
    }

    // Default AVURLAsset policy resolves local-to-local references.
    try #require(try await AVURLAsset(url: reference).load(.isPlayable))

    do {
        _ = try await Player.asset(for: reference).load(.isPlayable)
        Issue.record("Expected external local reference to be rejected")
    } catch {
        #expect(isForbiddenReferenceError(error))
    }

    #expect(await Player.pictureSize(of: reference) == nil)

    do {
        _ = try await Player.frame(of: reference, at: 0)
        Issue.record("Expected frame extraction to reject external local reference")
    } catch {
        #expect(isForbiddenReferenceError(error))
    }

    do {
        _ = try await Player.playableFile(for: reference, in: copies)
        Issue.record("Expected playableFile to reject external local reference")
    } catch PlaybackError.unplayable {
    } catch {
        Issue.record("Expected PlaybackError.unplayable, got \(error)")
    }
    #expect(!FileManager.default.fileExists(atPath: copies.path(percentEncoded: false)))
}

@MainActor
@Test func selfContainedFixturesStillPlayAndExposeVideoGeometry() async throws {
    let video = formatFixtures.appending(path: "clip-video.mp4")
    let copies = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let player = Player(defaults: MemoryDefaults(), copies: copies)
    defer {
        player.stop()
        try? FileManager.default.removeItem(at: copies)
    }

    let playable = try await Player.playableFile(for: video, in: copies)
    #expect(playable == video)
    #expect(await Player.pictureSize(of: video) == CGSize(width: 160, height: 120))
    let frame = try await Player.frame(of: video, at: 0.5)
    #expect(frame.width == 160)
    #expect(frame.height == 120)

    player.prepare(video, at: 0)
    for _ in 0..<100 where !(player.isOpen && player.duration > 0) {
        try await Task.sleep(for: .milliseconds(50))
    }
    try #require(player.isOpen)
    #expect(player.duration > 3)
    let openAsset = try #require(player.player?.currentItem?.asset as? AVURLAsset)
    #expect(openAsset.referenceRestrictions == .forbidAll)
}

@MainActor
@Test func playbackInterruptionsWatchesAndReleasesDefaultOutput() {
    let player = Player(defaults: MemoryDefaults())
    let inactive = PlaybackInterruptions(
        player: player, center: NotificationCenter(), watchesOutput: false)
    #expect(!inactive.isWatchingOutput)

    var active: PlaybackInterruptions? = PlaybackInterruptions(
        player: player, center: NotificationCenter(), watchesOutput: true)
    #expect(active?.isWatchingOutput == true)
    active = nil
}

/// Replacing a non-native recording at the same path invalidates `keptCopy`
/// even when the modification date is preserved, whether replaced atomically
/// (new file identity) or overwritten in place (different size).
@MainActor
@Test func keptCopyInvalidatesWhenFileIsReplacedWithSameModificationDate() async throws {
    let mkv = formatFixtures.appending(path: "clip.mkv")
    let videoMkv = formatFixtures.appending(path: "clip-video.mkv")
    let work = URL.temporaryDirectory.appending(path: "kept-\(UUID().uuidString)")
    let copies = work.appending(path: "copies")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let recording = work.appending(path: "lecture.mkv")
    let preservedDate = Date(timeIntervalSince1970: 1_700_000_000)
    let player = Player(defaults: MemoryDefaults(), copies: copies)
    defer {
        player.stop()
        player.discardCopy()
        try? FileManager.default.removeItem(at: work)
    }

    try Data(contentsOf: mkv).write(to: recording)
    try FileManager.default.setAttributes(
        [.modificationDate: preservedDate], ofItemAtPath: recording.path(percentEncoded: false))

    let first = try await playAndCollectCopy(of: recording, on: player)
    #expect(first.identity?.modified == preservedDate)
    #expect(try await playAndCollectCopy(of: recording, on: player) == first)

    // Atomic replacement: identical size and modification date, new inode.
    try Data(contentsOf: mkv).write(to: recording, options: .atomic)
    try FileManager.default.setAttributes(
        [.modificationDate: preservedDate], ofItemAtPath: recording.path(percentEncoded: false))
    let replacedIdentity = try #require(Player.FileIdentity(of: recording))
    #expect(replacedIdentity.modified == preservedDate)
    #expect(replacedIdentity.size == first.identity?.size)
    #expect(replacedIdentity != first.identity)

    let second = try await playAndCollectCopy(of: recording, on: player)
    #expect(second.file != first.file)
    #expect(!FileManager.default.fileExists(atPath: first.file.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: second.file.path(percentEncoded: false)))

    // In-place overwrite: same inode and modification date, different size.
    try Data(contentsOf: videoMkv).write(to: recording)
    try FileManager.default.setAttributes(
        [.modificationDate: preservedDate], ofItemAtPath: recording.path(percentEncoded: false))
    let overwrittenIdentity = try #require(Player.FileIdentity(of: recording))
    #expect(overwrittenIdentity.modified == preservedDate)
    #expect(overwrittenIdentity.size != second.identity?.size)

    let third = try await playAndCollectCopy(of: recording, on: player)
    #expect(third.file != second.file)
    #expect(!FileManager.default.fileExists(atPath: second.file.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: third.file.path(percentEncoded: false)))

    #expect(Player.FileIdentity(of: work.appending(path: "missing.mkv")) == nil)
    #expect(Player.FileIdentity(of: work) == nil)
}

/// Replacing the target of a symlinked recording invalidates `keptCopy` even
/// though the symlink itself keeps the same inode, size, and modification date.
@MainActor
@Test func keptCopyInvalidatesWhenSymlinkTargetIsReplaced() async throws {
    let mkv = formatFixtures.appending(path: "clip.mkv")
    let videoMkv = formatFixtures.appending(path: "clip-video.mkv")
    let work = URL.temporaryDirectory.appending(path: "kept-link-\(UUID().uuidString)")
    let copies = work.appending(path: "copies")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let target = work.appending(path: "target.mkv")
    let link = work.appending(path: "lecture.mkv")
    let preservedDate = Date(timeIntervalSince1970: 1_700_000_000)
    let player = Player(defaults: MemoryDefaults(), copies: copies)
    defer {
        player.stop()
        player.discardCopy()
        try? FileManager.default.removeItem(at: work)
    }

    try Data(contentsOf: mkv).write(to: target)
    try FileManager.default.setAttributes(
        [.modificationDate: preservedDate], ofItemAtPath: target.path(percentEncoded: false))
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let first = try await playAndCollectCopy(of: link, on: player)
    #expect(try await playAndCollectCopy(of: link, on: player) == first)

    // Replace the symlink target in place while keeping the target's mtime and
    // leaving the symlink itself untouched.
    try Data(contentsOf: videoMkv).write(to: target)
    try FileManager.default.setAttributes(
        [.modificationDate: preservedDate], ofItemAtPath: target.path(percentEncoded: false))

    let second = try await playAndCollectCopy(of: link, on: player)
    #expect(second.file != first.file)
    #expect(!FileManager.default.fileExists(atPath: first.file.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: second.file.path(percentEncoded: false)))

    let broken = work.appending(path: "broken.mkv")
    try FileManager.default.createSymbolicLink(
        atPath: broken.path(percentEncoded: false), withDestinationPath: "missing.mkv")
    #expect(Player.FileIdentity(of: broken) == nil)
}
