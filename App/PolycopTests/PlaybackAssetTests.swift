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
    let hostOnly = try #require(URL(string: "https://example.com"))
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
    #expect(
        PlaybackError.unplayable(hostOnly).errorDescription?.contains("https://example.com") == true
    )
}

@Test func playableFileRejectsDirectoriesWithoutCreatingCopies() async throws {
    let work = URL.temporaryDirectory.appending(path: "dir-\(UUID().uuidString)")
    let copies = work.appending(path: "copies")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    do {
        _ = try await Player.playableFile(for: work, in: copies)
        Issue.record("Expected playableFile to reject a directory")
    } catch PlaybackError.unplayable {
    } catch {
        Issue.record("Expected PlaybackError.unplayable, got \(error)")
    }
    #expect(!FileManager.default.fileExists(atPath: copies.path(percentEncoded: false)))
}

@Test func isForbiddenReferenceDetectsDirectAndWrappedErrors() {
    let forbidden = NSError(
        domain: AVFoundationErrorDomain,
        code: AVError.referenceForbiddenByReferencePolicy.rawValue)
    let wrapped = NSError(
        domain: NSCocoaErrorDomain, code: 1, userInfo: [NSUnderlyingErrorKey: forbidden])
    let multiWrapped = NSError(
        domain: NSCocoaErrorDomain, code: 2,
        userInfo: [NSMultipleUnderlyingErrorsKey: [NSError(domain: "other", code: 0), wrapped]])
    let unrelated = NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue)

    #expect(Player.isForbiddenReference(forbidden))
    #expect(Player.isForbiddenReference(wrapped))
    #expect(Player.isForbiddenReference(multiWrapped))
    #expect(!Player.isForbiddenReference(unrelated))
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
        #expect(Player.isForbiddenReference(error))
    }

    #expect(await Player.pictureSize(of: reference) == nil)

    do {
        _ = try await Player.frame(of: reference, at: 0)
        Issue.record("Expected frame extraction to reject external local reference")
    } catch {
        #expect(Player.isForbiddenReference(error))
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
@Test func playerRefusesExternalLocalReferenceEndToEnd() async throws {
    let video = formatFixtures.appending(path: "clip-video.mp4")
    let reference = URL.temporaryDirectory.appending(path: "ref-play-\(UUID().uuidString).mov")
    let copies = URL.temporaryDirectory.appending(path: "ref-play-copies-\(UUID().uuidString)")
    try referenceMovie(pointingTo: video).write(to: reference)
    let player = Player(defaults: MemoryDefaults(), copies: copies)
    defer {
        player.stop()
        player.discardCopy()
        try? FileManager.default.removeItem(at: reference)
        try? FileManager.default.removeItem(at: copies)
    }

    player.play(reference, from: 0)
    for _ in 0..<100 where player.isPreparing {
        try await Task.sleep(for: .milliseconds(50))
    }

    #expect(!player.isPreparing)
    #expect(!player.isOpen)
    #expect(!player.isPlaying)
    #expect(player.failure != nil)
    #expect(player.keptCopy == nil)
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

/// Verifies `PlaybackInterruptions` registers its CoreAudio default-output
/// listener when `watchesOutput` is enabled and tears down cleanly (deinit
/// itself only logs non-`noErr` removal statuses).
@MainActor
@Test func playbackInterruptionsRegistersAndTearsDownOutputListener() {
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
    let preservedSeconds = 1_700_000_000
    let preservedDate = Date(timeIntervalSince1970: TimeInterval(preservedSeconds))
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
    #expect(first.identity?.modifiedSeconds == preservedSeconds)
    #expect(try await playAndCollectCopy(of: recording, on: player) == first)

    // Atomic replacement: identical size and modification date, new inode.
    try Data(contentsOf: mkv).write(to: recording, options: .atomic)
    try FileManager.default.setAttributes(
        [.modificationDate: preservedDate], ofItemAtPath: recording.path(percentEncoded: false))
    let replacedIdentity = try #require(Player.FileIdentity(of: recording))
    #expect(replacedIdentity.modifiedSeconds == preservedSeconds)
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
    #expect(overwrittenIdentity.modifiedSeconds == preservedSeconds)
    #expect(overwrittenIdentity.size != second.identity?.size)

    let third = try await playAndCollectCopy(of: recording, on: player)
    #expect(third.file != second.file)
    #expect(!FileManager.default.fileExists(atPath: second.file.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: third.file.path(percentEncoded: false)))

    #expect(Player.FileIdentity(of: work.appending(path: "missing.mkv")) == nil)
    #expect(Player.FileIdentity(of: work) == nil)
}

/// Editing a relative symlink's target or retargeting the symlink to another
/// file with the same size and modification date invalidates `keptCopy`.
@MainActor
@Test func keptCopyInvalidatesWhenSymlinkTargetChangesOrRetargets() async throws {
    let mkv = formatFixtures.appending(path: "clip.mkv")
    let videoMkv = formatFixtures.appending(path: "clip-video.mkv")
    let work = URL.temporaryDirectory.appending(path: "kept-link-\(UUID().uuidString)")
    let copies = work.appending(path: "copies")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let target = work.appending(path: "target.mkv")
    let secondTarget = work.appending(path: "target-two.mkv")
    let link = work.appending(path: "lecture.mkv")
    let preservedSeconds = 1_700_000_000
    let preservedDate = Date(timeIntervalSince1970: TimeInterval(preservedSeconds))
    let player = Player(defaults: MemoryDefaults(), copies: copies)
    defer {
        player.stop()
        player.discardCopy()
        try? FileManager.default.removeItem(at: work)
    }

    try Data(contentsOf: mkv).write(to: target)
    try FileManager.default.setAttributes(
        [.modificationDate: preservedDate], ofItemAtPath: target.path(percentEncoded: false))
    try FileManager.default.createSymbolicLink(
        atPath: link.path(percentEncoded: false), withDestinationPath: "target.mkv")

    let first = try await playAndCollectCopy(of: link, on: player)
    #expect(try await playAndCollectCopy(of: link, on: player) == first)

    // In-place overwrite of the target with preserved mtime; symlink stays untouched.
    try Data(contentsOf: videoMkv).write(to: target)
    try FileManager.default.setAttributes(
        [.modificationDate: preservedDate], ofItemAtPath: target.path(percentEncoded: false))

    let second = try await playAndCollectCopy(of: link, on: player)
    #expect(second.file != first.file)
    #expect(!FileManager.default.fileExists(atPath: first.file.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: second.file.path(percentEncoded: false)))

    // Retarget the symlink to a different file with identical size and mtime.
    try Data(contentsOf: videoMkv).write(to: secondTarget)
    try FileManager.default.setAttributes(
        [.modificationDate: preservedDate], ofItemAtPath: secondTarget.path(percentEncoded: false))
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(
        atPath: link.path(percentEncoded: false), withDestinationPath: "target-two.mkv")
    let retargetedIdentity = try #require(Player.FileIdentity(of: link))
    #expect(retargetedIdentity.size == second.identity?.size)
    #expect(retargetedIdentity.modifiedSeconds == preservedSeconds)
    #expect(retargetedIdentity != second.identity)

    let third = try await playAndCollectCopy(of: link, on: player)
    #expect(third.file != second.file)
    #expect(!FileManager.default.fileExists(atPath: second.file.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: third.file.path(percentEncoded: false)))

    let broken = work.appending(path: "broken.mkv")
    try FileManager.default.createSymbolicLink(
        atPath: broken.path(percentEncoded: false), withDestinationPath: "missing.mkv")
    #expect(Player.FileIdentity(of: broken) == nil)
}

/// Discarding the cache while a decode is in flight invalidates the request,
/// leaving `kept` empty and removing any newly decoded file.
@MainActor
@Test func copyCacheDiscardDuringInFlightDecodeLeavesNoLeakedCopy() async throws {
    let mkv = formatFixtures.appending(path: "clip.mkv")
    let copies = URL.temporaryDirectory.appending(path: "discard-race-\(UUID().uuidString)")
    let cache = Player.CopyCache(folder: copies)
    defer {
        cache.discard()
        try? FileManager.default.removeItem(at: copies)
    }

    var started = false
    let decode = Task {
        started = true
        return try await cache.playable(mkv)
    }
    while !started { await Task.yield() }
    cache.discard()

    await #expect(throws: CancellationError.self) {
        _ = try await decode.value
    }
    #expect(cache.kept == nil)
    let remaining =
        (try? FileManager.default.contentsOfDirectory(atPath: copies.path(percentEncoded: false)))
        ?? []
    #expect(remaining.isEmpty)
}
