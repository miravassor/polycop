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

    /// How much of ffmpeg's diagnostic output is kept in memory for error
    /// messages and logs. A damaged file can make ffmpeg log a line per
    /// frame, more than is worth holding or reading.
    static let logTail = 8 << 10

    /// The only ffmpeg diagnostic text the app reads directly: when a file has
    /// a video track or metadata and no audio stream, ffmpeg 9.0.2 exits with
    /// status 234 and prints `"Output file does not contain any stream"`.
    /// Guarded by `aRecordingWithNoSoundSaysSoRatherThanReadingAsDamaged` in
    /// `RecoveryTests` and `reportsAVideoOnlyRecordingAsHavingNoAudioTrack` in
    /// `AudioDecoderTests`.
    private static let noAudioStreamDiagnostic = "does not contain any stream"

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

    /// Keeps only the last `capacity` bytes appended, overwriting older bytes
    /// in place once full so memory stays bounded regardless of stream length.
    private struct RingBuffer {
        let capacity: Int
        private var storage: [UInt8] = []
        private var writeIndex = 0

        mutating func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            if chunk.count >= capacity {
                let start = chunk.index(chunk.endIndex, offsetBy: -capacity)
                storage = Array(chunk[start...])
                writeIndex = 0
                return
            }
            var slice = chunk[...]
            if storage.count < capacity {
                let take = min(slice.count, capacity - storage.count)
                let split = slice.index(slice.startIndex, offsetBy: take)
                storage.append(contentsOf: slice[..<split])
                slice = slice[split...]
                if slice.isEmpty { return }
            }
            let firstCount = min(slice.count, capacity - writeIndex)
            let split = slice.index(slice.startIndex, offsetBy: firstCount)
            storage.replaceSubrange(writeIndex..<(writeIndex + firstCount), with: slice[..<split])
            let secondCount = slice.count - firstCount
            if secondCount > 0 {
                storage.replaceSubrange(0..<secondCount, with: slice[split...])
            }
            writeIndex = (writeIndex + slice.count) % capacity
        }

        var data: Data {
            if storage.count < capacity || writeIndex == 0 {
                return Data(storage)
            }
            var ordered = Data()
            ordered.reserveCapacity(capacity)
            ordered.append(contentsOf: storage[writeIndex...])
            ordered.append(contentsOf: storage[..<writeIndex])
            return ordered
        }
    }

    /// Drains a pipe's read end on a dedicated background queue until EOF,
    /// keeping only the last `logTail` bytes in memory so a noisy helper
    /// cannot fill the pipe buffer or grow memory without bound.
    struct ErrorTail: Sendable {
        private let group: DispatchGroup
        private let result: OSAllocatedUnfairLock<Data>

        private init(group: DispatchGroup, result: OSAllocatedUnfairLock<Data>) {
            self.group = group
            self.result = result
        }

        /// Starts draining `reading` until EOF, then closes it. The draining
        /// closure owns `reading` exclusively until `wait()` or `finish()`
        /// returns, and the caller must ensure the write end closes (such as
        /// by waiting for the child process to exit) before waiting.
        static func drain(_ reading: FileHandle) -> Self {
            let group = DispatchGroup()
            let result = OSAllocatedUnfairLock(initialState: Data())
            group.enter()
            errorQueue.async {
                defer {
                    try? reading.close()
                    group.leave()
                }
                var buffer = RingBuffer(capacity: logTail)
                // `read(upToCount:)` coalesces reads up to `logTail` and returns
                // `nil` at EOF without raising Objective-C exceptions.
                while let chunk = try? reading.read(upToCount: logTail), !chunk.isEmpty {
                    buffer.append(chunk)
                }
                let kept = buffer.data
                result.withLock { $0 = kept }
            }
            return Self(group: group, result: result)
        }

        /// Waits until EOF has been read and the underlying handle closed.
        func wait() {
            group.wait()
        }

        /// Waits for EOF and decodes the kept diagnostic tail.
        func finish() -> String {
            wait()
            return String(decoding: result.withLock { $0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Decoding an hour takes seconds and must not hold the window. Cancelling
    /// the task stops ffmpeg itself, rather than leaving it running unwatched.
    ///
    /// `maximumDuration` is a test seam for verifying the recording-length
    /// limit without a four-hour fixture; production callers use the default.
    static func samples(
        of recording: URL, maximumDuration: TimeInterval = longestRecording
    ) async throws
        -> [Float]
    {
        precondition(
            maximumDuration.isFinite && maximumDuration >= 0
                && maximumDuration <= longestRecording,
            "maximumDuration must be finite and within 0...longestRecording"
        )
        try verifyRegularFile(recording)
        let sampleLimit = Int(maximumDuration * Double(sampleRate))
        return try await runCancellable { run in
            try decode(recording, run, sampleLimit: sampleLimit)
        }
    }

    /// Writes a 16-bit WAV copy that AVFoundation plays, from ffmpeg straight
    /// to `file`, so memory stays flat however long the recording. Like a
    /// decode, it stops ffmpeg when the task is cancelled.
    static func writePlayableCopy(of recording: URL, to file: URL) async throws {
        try verifyRegularFile(recording)
        guard file.isFileURL else {
            throw AudioError.unreadable(recording, detail: "Expected a local file")
        }
        try await runCancellable { run in
            try withHelper(
                [
                    "-i", recording.path(percentEncoded: false),
                    "-vn", "-ac", "1", "-ar", String(sampleRate),
                    "-t", String(Int(longestRecording)),
                    "-c:a", "pcm_s16le", "-f", "wav", "-y", file.path(percentEncoded: false),
                ], on: recording, run, output: FileHandle.nullDevice
            ) {}
        }
    }

    private static func verifyRegularFile(_ recording: URL) throws {
        guard recording.isFileURL else {
            throw AudioError.unreadable(recording, detail: "Expected a local file")
        }
        // Only a file that is not there has moved; a folder without access
        // or a volume that fails is reported as it is.
        let values: URLResourceValues
        do {
            values = try recording.resourceValues(forKeys: [.isRegularFileKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw AudioError.missing(recording)
        } catch {
            throw AudioError.unreadable(recording, detail: error.localizedDescription)
        }
        guard let regular = values.isRegularFile else { throw AudioError.missing(recording) }
        guard regular else {
            throw AudioError.unreadable(recording, detail: "Expected a regular file")
        }
    }

    /// Runs blocking ffmpeg work on the decoding queue and forwards task
    /// cancellation to the active process under `Run`'s lock.
    private static func runCancellable<Result: Sendable>(
        _ work: @escaping @Sendable (OSAllocatedUnfairLock<Run>) throws -> Result
    ) async throws -> Result {
        let run = OSAllocatedUnfairLock(initialState: Run())
        return try await withTaskCancellationHandler {
            try await queue.run { try work(run) }
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

    private static let errorQueue = DispatchQueue(
        label: "io.github.miravassor.Polycop.audio.error", qos: .userInitiated,
        attributes: .concurrent)

    private static func decode(
        _ recording: URL, _ run: OSAllocatedUnfairLock<Run>, sampleLimit: Int
    ) throws -> [Float] {
        let output = Pipe()
        let arguments = [
            "-i", recording.path(percentEncoded: false),
            "-vn", "-ac", "1", "-ar", String(sampleRate),
            "-f", "f32le", "-",
        ]
        let samples = try withHelper(arguments, on: recording, run, output: output) {
            // A pipe holds 64 kB and an hour of speech is 230 MB, so the samples
            // are read while ffmpeg writes them. They go straight into the array
            // the engine is given, because holding the bytes and a copy of them
            // at once would cost twice the memory of the recording, 1.8 GB at
            // the four-hour limit.
            var samples: [Float] = []
            var partialSample: [UInt8] = []
            let reading = output.fileHandleForReading
            defer { try? reading.close() }
            while case let chunk = reading.availableData, !chunk.isEmpty {
                let addedSamples = (partialSample.count + chunk.count) / MemoryLayout<Float>.size
                guard samples.count + addedSamples <= sampleLimit else {
                    throw AudioError.tooLong
                }
                collect(chunk, into: &samples, carrying: &partialSample)
            }
            return samples
        }
        guard !samples.isEmpty else {
            throw AudioError.noAudioTrack(recording)
        }
        return samples
    }

    /// Runs the bundled ffmpeg on `recording` with stderr drained into a
    /// bounded ring buffer, runs `body` while ffmpeg executes, then turns a
    /// stop or a failure into the app's errors once it has ended.
    private static func withHelper<Result>(
        _ arguments: [String], on recording: URL, _ run: OSAllocatedUnfairLock<Run>,
        output: Any, _ body: () throws -> Result
    ) throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw AudioError.helperMissing
        }

        let process = Process()
        process.executableURL = helper
        process.arguments =
            ["-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe"] + arguments
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        // Passing the `Pipe` itself lets `Process.run()` close the parent's
        // write end automatically, so draining stderr hits EOF when ffmpeg exits.
        let errors = Pipe()
        process.standardError = errors

        // Launched and published under the lock, so a stop is either seen
        // here, before ffmpeg starts, or delivered to the process that runs.
        try run.withLock { state in
            if state.cancelled { throw CancellationError() }
            try process.run()
            state.process = process
        }
        let errorTail = ErrorTail.drain(errors.fileHandleForReading)
        var exited = false
        defer {
            if !exited {
                if process.isRunning { stop(process) }
                process.waitUntilExit()
            }
            errorTail.wait()
            run.withLock { $0.process = nil }
        }

        let result = try body()
        process.waitUntilExit()
        exited = true

        // A stopped process is not treated as a failed decode. The task is not
        // readable from this queue, so the stop is read from the lock that
        // recorded it.
        if run.withLock({ $0.cancelled }) { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let detail = errorTail.finish()
            if detail.contains(noAudioStreamDiagnostic) {
                throw AudioError.noAudioTrack(recording)
            }
            Log.media.error(
                "ffmpeg exited \(process.terminationStatus) on \(recording.lastPathComponent, privacy: .private): \(detail, privacy: .private)"
            )
            throw AudioError.unreadable(recording, detail: detail)
        }
        return result
    }

    /// ffmpeg writes 32-bit floats and a pipe read can end in the middle of
    /// one, so the odd bytes wait here for the next chunk.
    private static func collect(
        _ chunk: Data, into samples: inout [Float], carrying partial: inout [UInt8]
    ) {
        var bytes = partial
        bytes.append(contentsOf: chunk)
        let size = MemoryLayout<Float>.size
        let whole = bytes.count - bytes.count % size
        let first = samples.count
        samples.append(contentsOf: repeatElement(0, count: whole / size))
        // Copied as bytes into the floats: memory holding bytes cannot be read
        // as floats in place without breaking Swift's rules for typed memory.
        samples.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBytes { source in
                UnsafeMutableRawBufferPointer(rebasing: destination[(first * size)...])
                    .copyMemory(from: UnsafeRawBufferPointer(rebasing: source[..<whole]))
            }
        }
        partial = Array(bytes[whole...])
    }
}
