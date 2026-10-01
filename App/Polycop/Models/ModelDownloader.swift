// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

nonisolated enum DownloadError: LocalizedError {
    case httpFailure(Int)
    case checksumMismatch(Model)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .tooLarge:
            String(localized: "The download exceeded the model's expected size and was stopped.")
        case .httpFailure(let code):
            String(localized: "The download failed (code \(code)).")
        case .checksumMismatch(let model):
            String(
                localized:
                    "The file received does not match \(model.name) and was not installed."
            )
        }
    }
}

/// Downloads a model into the store, with progress, and continues an
/// interrupted or stopped transfer rather than starting it again.
///
/// Uses a session delegate rather than `download(from:delegate:)`. The
/// asynchronous convenience methods deliver only the callbacks their own
/// handler does not cover, so a delegate passed to them never sees progress.
nonisolated enum ModelDownloader {
    /// `url`, `folder` and `configuration` are for tests, which serve the
    /// file themselves; the app downloads the pinned address into the store.
    static func download(
        _ model: Model,
        from url: URL? = nil,
        in folder: URL = ModelStore.directory,
        configuration: URLSessionConfiguration = configuration,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        if ModelStore.isInstalled(model, in: folder) {
            return ModelStore.location(of: model, in: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let place = Place(
            url: url ?? model.url, folder: folder, configuration: configuration,
            onProgress: onProgress)

        let resumeFile = ModelStore.resumeFile(of: model, in: folder)
        if let resumeData = try? Data(contentsOf: resumeFile) {
            do {
                return try await fetch(model, into: place, resumingFrom: resumeData)
            } catch let error as DownloadError {
                // Resume data replays the request it was made from, whose
                // signed redirect may have expired, and the bytes it continues
                // may be wrong. Once, the download starts over from the pinned
                // address instead.
                Log.models.notice(
                    "a resumed download failed, starting over: \(error, privacy: .public)")
                try? FileManager.default.removeItem(at: resumeFile)
            }
        }
        return try await fetch(model, into: place, resumingFrom: nil)
    }

    /// Where one download comes from and goes.
    private struct Place {
        let url: URL
        let folder: URL
        let configuration: URLSessionConfiguration
        let onProgress: @Sendable (Double) -> Void
    }

    private static func fetch(
        _ model: Model, into place: Place, resumingFrom resumeData: Data?
    ) async throws -> URL {
        let resumeFile = ModelStore.resumeFile(of: model, in: place.folder)
        let transfer = Transfer(
            limit: model.bytes, folder: place.folder, onProgress: place.onProgress)

        let received: URL
        do {
            received = try await transfer.run(
                url: place.url, resumeFrom: resumeData, configuration: place.configuration)
        } catch {
            // URLSession hands back the bytes it fetched when a transfer fails
            // or is stopped, as by Cancel or Quit, so the next attempt does
            // not start from zero.
            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData]
                as? Data
            {
                try? resumeData.write(to: resumeFile)
            } else if !isStop(error) {
                // Resume data the server refuses would otherwise fail every retry.
                try? FileManager.default.removeItem(at: resumeFile)
            }
            throw error
        }
        try? FileManager.default.removeItem(at: resumeFile)

        // What arrived is removed on every path but a successful install.
        var installed = false
        defer {
            if !installed { try? FileManager.default.removeItem(at: received) }
        }

        // The transfer may already be finished when the stop arrives.
        try Task.checkCancellation()
        if let code = transfer.statusCode, !(200..<300).contains(code) {
            throw DownloadError.httpFailure(code)
        }

        // The hash is the only proof that these are the pinned weights.
        guard try await ModelStore.sha256(of: received) == model.sha256 else {
            throw DownloadError.checksumMismatch(model)
        }
        // A stop can arrive after hashing and before publication.
        try Task.checkCancellation()

        let destination = ModelStore.location(of: model, in: place.folder)
        try ModelStore.publish(received, as: destination)
        installed = true
        return destination
    }

    /// A stop asked for, rather than a transfer that failed.
    private static func isStop(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Fixed values replace the headers the system would add, which name the
    /// Mac and the user's languages, as the update check does. Resume data
    /// replays the first request, so they are set on it.
    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Polycop", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    /// Nothing kept between downloads, so one cannot be linked to the next:
    /// no cookie, no cache, no stored credential.
    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }

    /// Drives one download task and turns its callbacks into a single
    /// asynchronous call. The session holds this object until it is invalidated.
    private final class Transfer: NSObject, URLSessionDownloadDelegate, Sendable {
        private let onProgress: @Sendable (Double) -> Void
        private let limit: Int64
        /// Where the received file waits for its hash: on the store's volume,
        /// so publishing it is a rename, and swept at launch if the app stops
        /// before then.
        private let folder: URL
        /// The last whole percentage reported. Callbacks arrive many times a
        /// second, and each report redraws whatever shows the download.
        private let reported = OSAllocatedUnfairLock(initialState: -1)
        private let waiting = OSAllocatedUnfairLock(
            initialState: CheckedContinuation<URL, any Error>?.none)
        private let status = OSAllocatedUnfairLock(initialState: Int?.none)
        private let running = OSAllocatedUnfairLock(initialState: Run())

        /// A stop and the transfer it must reach, under one lock, so a stop that
        /// arrives before the transfer starts is not lost.
        private struct Run {
            var cancelled = false
            var task: URLSessionDownloadTask?
        }

        var statusCode: Int? { status.withLock { $0 } }

        init(limit: Int64, folder: URL, onProgress: @escaping @Sendable (Double) -> Void) {
            self.limit = limit
            self.folder = folder
            self.onProgress = onProgress
        }

        func run(
            url: URL, resumeFrom resumeData: Data?, configuration: URLSessionConfiguration
        ) async throws -> URL {
            let session = URLSession(
                configuration: configuration, delegate: self, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiting.withLock { $0 = continuation }
                    let task =
                        if let resumeData {
                            session.downloadTask(withResumeData: resumeData)
                        } else {
                            session.downloadTask(with: ModelDownloader.request(for: url))
                        }
                    // Published under the lock, so a stop is either seen here,
                    // before the transfer starts, or delivered to it.
                    let started = running.withLock { state -> Bool in
                        guard !state.cancelled else { return false }
                        state.task = task
                        return true
                    }
                    if started {
                        task.resume()
                    } else {
                        task.cancel()
                        finish(.failure(CancellationError()))
                    }
                }
            } onCancel: {
                // Cancelling the Swift task has to reach the transfer itself,
                // which otherwise keeps running and installs after the stop.
                // Stopped with resume data, so Cancel and Quit keep what
                // was downloaded. It arrives with the transfer's error.
                running.withLock {
                    $0.cancelled = true
                    $0.task?.cancel(byProducingResumeData: { _ in })
                }
            }
        }

        /// Whichever callback arrives first resumes the call, exactly once.
        private func finish(_ result: Result<URL, any Error>) {
            let continuation = waiting.withLock { waiting -> CheckedContinuation<URL, any Error>? in
                defer { waiting = nil }
                return waiting
            }
            if let continuation {
                continuation.resume(with: result)
            } else if case .success(let file) = result {
                try? FileManager.default.removeItem(at: file)
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesWritten <= limit else {
                downloadTask.cancel()
                finish(.failure(DownloadError.tooLarge))
                return
            }
            guard totalBytesExpectedToWrite > 0 else { return }
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let percent = Int(progress * 100)
            let isNew = reported.withLock { last in
                defer { last = percent }
                return percent != last
            }
            if isNew { onProgress(progress) }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            status.withLock { $0 = (downloadTask.response as? HTTPURLResponse)?.statusCode }

            // The temporary file is removed as soon as this returns.
            let kept = folder.appending(path: UUID().uuidString + ".part")
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                finish(.success(kept))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: (any Error)?
        ) {
            guard let error else { return }
            finish(.failure(error))
        }
    }
}
