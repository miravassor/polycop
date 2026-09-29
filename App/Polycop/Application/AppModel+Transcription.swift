// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

// MARK: Transcription queue and runs

extension AppModel {
    func chooseRecordings() {
        guard !isShuttingDown else { return }
        pane = .new
        recordingsRequest = UUID()
    }

    func chooseTranscriptImport() {
        guard !isShuttingDown, !stage.isBusy else { return }
        transcriptImportRequest = UUID()
    }

    func importTranscript(_ transcript: URL, audio: URL) {
        guard !isShuttingDown, !stage.isBusy else { return }
        failure = nil
        stage = .decoding
        let number = beginJob()
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let parsed = try await TranscriptImport.read(transcript)
                let duration =
                    Double(try await AudioDecoder.samples(of: audio).count)
                    / Double(AudioDecoder.sampleRate)
                try Task.checkCancellation()
                guard isCurrent(number) else { return }
                var entry = try parsed.entry(
                    recording: audio, duration: duration,
                    source: transcript.lastPathComponent)
                let names = Set(entries.map(\.name))
                if names.contains(entry.name) {
                    entry.title = Entry.freeName(from: entry.name, among: names)
                }
                entries.insert(entry, at: 0)
                store(entry)
                pane = .entry(entry.id)
                finish()
            } catch is CancellationError {
                guard isCurrent(number) else { return }
                finish()
            } catch {
                guard isCurrent(number) else { return }
                failure = error.localizedDescription
                finish()
            }
        }
    }

    /// Adds recordings with the settings on screen now. They run one after
    /// another in the order given, and the first one is shown.
    func transcribe(_ files: [URL]) {
        guard !files.isEmpty, !isShuttingDown else { return }
        guard files.allSatisfy({ $0.isFileURL }) else {
            failure = String(localized: "Choose audio or video files stored on this Mac.")
            return
        }
        // A folder dropped from the Finder is a file URL too. Whether it holds
        // audio is left to ffmpeg, but a recording the app cannot even open
        // should not become a library entry that is bound to fail.
        let files = files.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard !files.isEmpty else {
            failure = String(localized: "Choose audio or video files, not folders.")
            return
        }
        // A user with no model installed should not have to choose one first.
        // Start fetches the recommended model on its own.
        if !isInstalled(selected), selectedCatalogue == nil {
            selected = ModelCatalog.recommended.id
        }
        failure = nil
        let (glossary, lost) = chosenGlossary()
        let now = Date.now
        // A millisecond apart, so the order given survives in the list.
        var taken = Set(entries.map(\.name))
        let added = files.enumerated().map { index, file in
            var entry = Entry(
                recording: file, modelFile: selected, glossary: glossary,
                // Subtitles are an export choice, made on the transcript
                // itself once there is one to look at, not a decoding setting.
                skipsSilence: skipsSilence && silenceApplies, subtitles: false,
                language: language, added: now.addingTimeInterval(Double(index) / 1000))
            // The same lecture added twice, or two files of the same name from
            // different folders, would otherwise be two rows called the same
            // thing, offering the save panel the same name.
            if taken.contains(entry.name) {
                entry.title = Entry.freeName(from: entry.name, among: taken)
            }
            taken.insert(entry.name)
            return entry
        }
        entries.insert(contentsOf: added.reversed(), at: 0)
        added.forEach(store)
        // Adding leaves the user on the page that holds the queue and the
        // settings, since more files can follow and the settings still apply
        // to all of them until Start.
        pane = .new
        // Said last: showing the entry clears what the window was reporting.
        if let lost { failure = lostGlossary(lost) }
    }

    /// Starts the recordings that are waiting, oldest first. Nothing starts on
    /// its own: adding a recording is not the same as asking for it to be
    /// transcribed, and a lecture takes minutes and uses the whole machine.
    ///
    /// Downloads the model first when it is missing, since that is part of
    /// the same request.
    func start() {
        guard !isShuttingDown, !stage.isBusy, busyEntry == nil, !waiting.isEmpty else { return }
        failure = nil
        scheduled.removeAll()
        // The settings on the page now are what these recordings are
        // transcribed with, not whatever the page showed when they were added.
        let (glossary, lost) = chosenGlossary()
        for entry in waiting {
            updateEntry(entry.id) {
                $0.adopt(
                    modelFile: selected, glossary: glossary, language: language,
                    skipsSilence: skipsSilence && silenceApplies)
            }
        }
        scheduled.formUnion(waiting.map(\.id))
        guard let next = nextInLine else { return }
        pane = .entry(next.id)
        if !isInstalled(next.modelFile),
            let wanted = ModelCatalog.model(next.modelFile)
        {
            download(wanted)
        } else {
            startNext()
        }
        // Said last: a transfer starting clears what the window was reporting.
        if let lost { failure = lostGlossary(lost) }
    }

    func isScheduled(_ id: Entry.ID) -> Bool { scheduled.contains(id) }

    func continueQueue() {
        guard !isShuttingDown, !stage.isBusy, busyEntry == nil else { return }
        if let missingModel {
            download(missingModel)
        } else {
            startNext()
        }
    }

    /// Whether anything is waiting to be started.
    var canStart: Bool {
        !isShuttingDown && !stage.isBusy && busyEntry == nil && !hasUnsavedHistory
            && !waiting.isEmpty
    }

    /// Takes every recording that has not started out of the library. None of
    /// them has been transcribed, so removing them loses no work.
    func clearQueue() {
        guard !isShuttingDown else { return }
        for entry in waiting { removeEntry(entry.id) }
    }

    /// Transcribes the recording again exactly as this entry was transcribed.
    /// The settings on screen may have changed since; a retry that used them
    /// instead would not be a retry of the same job.
    func retry(_ id: Entry.ID) {
        guard !isShuttingDown, let entry = entry(id), entry.state != .waiting,
            entry.state != .running
        else { return }
        failure = nil
        var again = entry.retrying()
        again.title = Entry.freeName(from: entry.name, among: Set(entries.map(\.name)))
        entries.insert(again, at: 0)
        scheduled.insert(again.id)
        store(again)
        pane = .entry(again.id)
        // Runs at once rather than waiting for Start, but downloads nothing: a
        // model deleted since would otherwise turn a retry into an unexpected
        // multi-gigabyte download. The recording waits, and the page offers it.
        startNext()
    }

    /// A new entry for the same recording, with the settings on screen now.
    func transcribeAgain(_ id: Entry.ID) {
        guard let entry = entry(id) else { return }
        transcribe([entry.location])
    }

    /// Stops and keeps everything decoded so far. The window says it is
    /// stopping until the engine has actually let go.
    func pause() {
        guard !isShuttingDown, case .transcribing(let progress) = stage else { return }
        pausedAt = progress
        pausing = true
        stage = .stopping
        work?.cancel()
    }

    func resume() {
        guard !isShuttingDown, case .paused = stage, let transcription = paused else { return }
        paused = nil
        stage = .loading
        run(transcription)
    }

    /// Stops the job or the transfer under way. A recording keeps what a pause
    /// had already decoded, and is marked stopped. The next recording starts
    /// only once the work has actually ended, so the window never claims to
    /// be free while ffmpeg or the engine is still finishing.
    func cancel() {
        guard stage.isBusy, !isShuttingDown else { return }
        pausing = false
        paused = nil
        stage = .stopping
        job += 1
        // Only a transcription becomes stopped. A repair leaves the transcript
        // as it was, and a transfer leaves no transcript at all.
        if let running {
            updateEntry(running) { $0.state = .stopped }
        }
        let stopping = work
        stopping?.cancel()
        // The handle stays in `work` until the work has ended, so quitting while
        // it stops still waits for it.
        Task { [weak self] in
            _ = await stopping?.value
            guard let self, !isShuttingDown, stage == .stopping else { return }
            work = nil
            finish()
        }
    }

    /// Starts the waiting entry added first, once nothing else is busy.
    func startNext() {
        guard !isShuttingDown, !hasUnsavedHistory, !stage.isBusy, busyEntry == nil,
            let next = nextInLine
        else { return }
        refreshInstalled()
        guard isInstalled(next.modelFile) else {
            // A model that the catalogue offers can still arrive: the recording
            // keeps its turn and the window offers the download. Cancelling a
            // transfer must not turn every recording behind it into a failure
            // of its own.
            guard !ModelCatalog.all.contains(where: { $0.id == next.modelFile }) else { return }
            updateEntry(next.id) {
                $0.state = .failed(
                    String(
                        localized:
                            "The model it needs is not installed. Download it, then transcribe again."
                    ))
            }
            startNext()
            return
        }
        running = next.id
        updateEntry(next.id) { $0.state = .running }
        stage = .decoding
        run(Transcription(id: next.id))
    }

    /// A job or a transfer has ended: the next recording starts, or the weights
    /// are let go when none waits.
    func finish() {
        guard !isShuttingDown else { return }
        job += 1
        work = nil
        if let running { scheduled.remove(running) }
        running = nil
        repairing = nil
        downloadingModel = nil
        stage = .waiting
        startNext()
        if busyEntry == nil { releaseEngine() }
    }

    /// Decodes if needed, opens the model if needed, then transcribes from the
    /// end of what the engine already wrote for this entry.
    private func run(_ transcription: Transcription) {
        let number = beginJob()
        let id = transcription.id
        guard let entry = entry(id) else {
            finish()
            return
        }
        let kept = entry.decoded
        // Taken once, when the transcript starts, so every layout of its text
        // gets the same corrections.
        if entry.courseCorrections == nil {
            let remembered = courseCorrections(for: entry)
            if !remembered.isEmpty { updateEntry(id) { $0.courseCorrections = remembered } }
        }
        let recording = recording(of: entry)
        let catalogued = ModelCatalog.model(entry.modelFile)
        var settings = DecodingSettings()
        settings.voiceActivityDetection = entry.skipsSilence
        settings.prompt = entry.prompt
        settings.language = entry.language ?? settings.language

        let started = Date.now
        work = Task { [weak self] in
            guard let self else { return }
            var transcription = transcription
            var settings = settings
            // Segments are collected as they arrive: a call stopped by a pause
            // returns nothing, and what it had decoded must survive.
            let collected = OSAllocatedUnfairLock(initialState: [Segment]())
            defer {
                // Stop and quit invalidate the job, but its completed segments still belong here.
                if self.entry(id)?.state == .stopped {
                    let result = kept + collected.withLock { $0 }
                    if result.count > kept.count {
                        updateEntry(id) { $0.publish(result, partial: true) }
                        recordTimeSpent(since: started, on: id)
                    }
                }
            }
            do {
                guard let catalogued else { throw ModelStore.ImportError.unrecognized }
                // The stage was set before this task started: setting it here
                // again would overwrite a cancel that came first, and the stop
                // would never complete.
                if transcription.samples.isEmpty {
                    transcription.samples = try await AudioDecoder.samples(of: recording)
                    try Task.checkCancellation()
                }
                guard isCurrent(number) else { return }
                let samples = transcription.samples
                let duration = Double(samples.count) / Double(AudioDecoder.sampleRate)
                updateEntry(id) { $0.duration = duration }
                // Every transcription that skips silences says how much of the
                // recording it left out, since some of it was speech.
                if settings.voiceActivityDetection, entry.speech == nil {
                    let speech = try await WhisperEngine.speech(in: samples, settings: settings)
                    try Task.checkCancellation()
                    guard isCurrent(number) else { return }
                    updateEntry(id) { $0.speech = speech }
                }

                let engine = try await preparedEngine(
                    for: catalogued, skipsSilence: settings.voiceActivityDetection)
                let aligned = (engine as? AudioCppEngine)?.aligns == true
                updateEntry(id) { $0.sentenceTimes = aligned ? true : nil }
                // whisper.cpp keeps only the last tokens of a long glossary and
                // only logs it, which the user never sees, so the warning is
                // shown here instead.
                if let whisper = engine as? WhisperEngine {
                    await limitContextToGlossary(&settings, of: id, on: whisper)
                }
                try Task.checkCancellation()
                guard isCurrent(number) else { return }

                let total = Double(transcription.samples.count) / Double(AudioDecoder.sampleRate)
                let from = kept.last?.end ?? 0
                if !kept.isEmpty {
                    updateEntry(id) { $0.resumedAt = ($0.resumedAt ?? []) + [from] }
                }
                stage = .transcribing(total > 0 ? from / total : 0)
                _ = try await engine.transcribe(
                    samples: transcription.samples,
                    settings: settings,
                    from: from,
                    onProgress: { [weak self] fraction in
                        let overall = total > 0 ? (from + fraction * (total - from)) / total : 0
                        Task { @MainActor in
                            // A pause already asked for must not be overwritten.
                            guard let self, self.isCurrent(number),
                                case .transcribing = self.stage
                            else { return }
                            self.stage = .transcribing(overall)
                        }
                    },
                    onSegment: { segment in collected.withLock { $0.append(segment) } })
                try Task.checkCancellation()
                guard isCurrent(number) else { return }

                let result = kept + collected.withLock { $0 }
                updateEntry(id) {
                    $0.publish(result, partial: false)
                    $0.sentenceTimes = aligned ? true : nil
                    $0.state = .finished
                }
                recordTimeSpent(since: started, on: id)
                finish()
            } catch is CancellationError {
                guard isCurrent(number) else { return }
                if pausing {
                    pausing = false
                    let result = kept + collected.withLock { $0 }
                    updateEntry(id) { $0.publish(result, partial: true) }
                    recordTimeSpent(since: started, on: id)
                    paused = transcription
                    stage = .paused(pausedAt)
                } else {
                    updateEntry(id) { $0.state = .stopped }
                    finish()
                }
            } catch {
                guard isCurrent(number) else { return }
                pausing = false
                let message = error.localizedDescription
                let result = kept + collected.withLock { $0 }
                updateEntry(id) {
                    $0.publish(result, partial: true)
                    $0.state = .failed(message)
                }
                recordTimeSpent(since: started, on: id)
                finish()
            }
        }
    }

    /// The engine that runs this model, opened unless the one loaded serves.
    func preparedEngine(for model: Model, skipsSilence: Bool) async throws
        -> any TranscriptionEngine
    {
        try Task.checkCancellation()
        // Qwen times its sentences when the aligner is installed, which is
        // part of the engine it opens.
        let aligner = ModelCatalog.qwenAligner
        let aligns =
            model.engine == .qwen && ModelStore.isInstalled(aligner)
            && Memory.areLikelyToFit(model, aligner)
        if engineFile != model.id || engineSkipsSilence != skipsSilence || engineAligns != aligns {
            releaseEngine()
        }
        if let engine { return engine }
        stage = .loading
        let opened = try await engines.open(model, aligns)
        try Task.checkCancellation()
        engine = opened
        engineFile = model.id
        engineSkipsSilence = skipsSilence
        engineAligns = aligns
        return opened
    }

    /// Adds what this run took to the time already spent on the entry, so a
    /// transcription resumed after a pause reports the whole of it.
    private func recordTimeSpent(since started: Date, on id: Entry.ID) {
        let taken = max(0, Date.now.timeIntervalSince(started))
        updateEntry(id) { $0.transcribedIn = ($0.transcribedIn ?? 0) + taken }
    }
}
