// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

nonisolated enum AudioError: LocalizedError, Equatable {
    case helperMissing
    case missing(URL)
    case unreadable(URL, detail: String)
    case noAudioTrack(URL)
    case tooLong

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            String(localized: "The audio converter is missing from the application.")
        case .tooLong:
            String(
                localized:
                    "This recording exceeds the four-hour limit. Split it into shorter recordings and try again."
            )
        case .missing(let recording):
            String(
                localized:
                    "The recording is no longer where it was: \(recording.path(percentEncoded: false))"
            )
        case .unreadable(let recording, _):
            String(localized: "The file could not be read: \(recording.lastPathComponent)")
        case .noAudioTrack(let recording):
            String(
                localized:
                    "The file contains no audio track: \(recording.lastPathComponent)"
            )
        }
    }
}

/// Turns a recording of any format into the samples whisper.cpp expects.
///
/// Runs everything through the bundled ffmpeg, so behaviour is the same on
/// macOS 14 and macOS 26, and formats AVFoundation refuses still open (on
/// macOS 26, AVFoundation reads none of Matroska, WebM or WMA). The call
/// blocks, so run it off the main actor.
nonisolated enum AudioDecoder {
    /// The only rate the models accept.
    static let sampleRate = 16000
    /// The longest recording the app accepts, which is what bounds the
    /// memory one decode can take.
    static let longestRecording: TimeInterval = 4 * 60 * 60

    static let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/ffmpeg")

    private static let queue = DispatchQueue(
        label: "io.github.miravassor.Polycop.audio", qos: .userInitiated)

    /// How much of ffmpeg's diagnostic is kept on disk, and how much of it
    /// reaches a message. A damaged file can make ffmpeg log a line per
    /// frame, more than is worth storing or reading.
    private static let logLimit = 4 << 20
    private static let logTail = 8 << 10

    /// How long a stopped ffmpeg is given to end before it is killed. It only
    /// has to close a file and exit; the wait is there so a stop cannot leave a
    /// process decoding unwatched if the signal is ever missed.
    private static let graceSeconds = 2.0

    /// A stop and the process it must reach, under one lock. A stop that
    /// arrives before ffmpeg starts is remembered and seen at launch, instead
    /// of finding no process and being lost.
    private struct Run {
        var cancelled = false
        var process: Process?
    }

    /// Decoding an hour takes seconds and must not hold the window. Cancelling
    /// the task stops ffmpeg itself, rather than leaving it running unwatched.
    static func samples(
        of recording: URL, maximumDuration: TimeInterval = longestRecording
    ) async throws
        -> [Float]
    {
        guard maximumDuration.isFinite, recording.isFileURL else {
            throw AudioError.unreadable(recording, detail: "Expected a local file")
        }
        guard
            let regular = try? recording.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile
        else { throw AudioError.missing(recording) }
        guard regular else {
            throw AudioError.unreadable(recording, detail: "Expected a regular file")
        }
        let byteLimit =
            Int(min(max(maximumDuration, 0), longestRecording) * Double(sampleRate))
            * MemoryLayout<Float>.size
        let run = OSAllocatedUnfairLock(initialState: Run())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        continuation.resume(
                            returning: try decode(recording, run, byteLimit: byteLimit))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            run.withLock {
                $0.cancelled = true
                if let process = $0.process { stop(process) }
            }
        }
    }

    /// Asks ffmpeg to end, then insists, because SIGTERM can be ignored. The
    /// wait runs on a queue of its own, since this is called on whichever
    /// thread cancelled the task, and the decoding queue is busy with that
    /// call.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        stoppingQueue.asyncAfter(deadline: .now() + graceSeconds) {
            guard process.isRunning else { return }
            Log.media.error("ffmpeg did not end when asked to stop; killing it")
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private static let stoppingQueue = DispatchQueue(
        label: "io.github.miravassor.Polycop.audio.stop")

    private static func decode(
        _ recording: URL, _ run: OSAllocatedUnfairLock<Run>, byteLimit: Int
    ) throws -> [Float] {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw AudioError.helperMissing
        }

        let process = Process()
        process.executableURL = helper
        process.arguments = [
            "-nostdin", "-v", "error",
            "-protocol_whitelist", "file,pipe",
            "-i", recording.path(percentEncoded: false),
            "-vn", "-ac", "1", "-ar", String(sampleRate),
            "-f", "f32le", "-",
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice

        // Errors go to a file, not to a second pipe, because reading two pipes
        // from one thread deadlocks as soon as either of them fills.
        let log = FileManager.default.temporaryDirectory
            .appending(path: "polycop-\(UUID().uuidString).log")
        FileManager.default.createFile(
            atPath: log.path(percentEncoded: false), contents: nil,
            attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: log) }
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close() }
        process.standardError = errors

        // Launched and published under the lock, so a stop is either seen
        // here, before ffmpeg starts, or delivered to the process that runs.
        try run.withLock { state in
            if state.cancelled { throw CancellationError() }
            try process.run()
            state.process = process
        }
        defer { run.withLock { $0.process = nil } }

        // A pipe holds 64 kB and an hour of speech is 230 MB, so the samples are
        // read while ffmpeg writes them. They go straight into the array the
        // engine is given, because holding the bytes and a copy of them at
        // once would cost twice the memory of the recording, 1.8 GB at the
        // four-hour limit.
        var samples: [Float] = []
        var partialSample: [UInt8] = []
        let sampleLimit = byteLimit / MemoryLayout<Float>.size
        let reading = output.fileHandleForReading
        while case let chunk = reading.availableData, !chunk.isEmpty {
            guard samples.count + chunk.count / MemoryLayout<Float>.size <= sampleLimit else {
                stop(process)
                try? reading.close()
                process.waitUntilExit()
                throw AudioError.tooLong
            }
            collect(chunk, into: &samples, carrying: &partialSample)
            capLog(log, errors)
        }
        process.waitUntilExit()

        // A stopped process is not treated as a failed decode. The task is not
        // readable from this queue, so the stop is read from the lock that
        // recorded it.
        if run.withLock({ $0.cancelled }) { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let detail = tail(of: log)
            // A file with a picture and no sound makes ffmpeg find nothing to
            // convert and stop before writing anything. On the bundled ffmpeg
            // 9.0.2 this exits with status 234 and this message, the only
            // ffmpeg output text the app reads directly.
            if detail.contains("does not contain any stream") {
                throw AudioError.noAudioTrack(recording)
            }
            Log.media.error(
                "ffmpeg exited \(process.terminationStatus) on \(recording.lastPathComponent, privacy: .private): \(detail, privacy: .private)"
            )
            throw AudioError.unreadable(recording, detail: detail)
        }
        guard !samples.isEmpty else {
            throw AudioError.noAudioTrack(recording)
        }
        return samples
    }

    /// ffmpeg writes 32-bit floats and a pipe read can end in the middle of
    /// one, so the odd bytes wait here for the next chunk.
    private static func collect(
        _ chunk: Data, into samples: inout [Float], carrying partial: inout [UInt8]
    ) {
        var bytes = partial
        bytes.append(contentsOf: chunk)
        let whole = bytes.count - bytes.count % MemoryLayout<Float>.size
        bytes.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            samples.append(
                contentsOf: UnsafeBufferPointer(
                    start: floats.baseAddress, count: whole / MemoryLayout<Float>.size))
        }
        partial = Array(bytes[whole...])
    }

    /// Caps the diagnostic log so it does not grow without bound. A file
    /// damaged frame by frame makes ffmpeg complain about every one of them;
    /// the last lines are the ones worth reading, and the handle is shared
    /// with ffmpeg, so rewinding it is what makes it overwrite the older ones.
    private static func capLog(_ log: URL, _ errors: FileHandle) {
        guard let size = try? errors.offset(), size > logLimit else { return }
        try? errors.truncate(atOffset: 0)
        try? errors.seek(toOffset: 0)
    }

    /// The end of the diagnostic, which is where ffmpeg says what went wrong.
    private static func tail(of log: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(logTail) ? size - UInt64(logTail) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
