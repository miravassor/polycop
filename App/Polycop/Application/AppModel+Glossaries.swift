// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: Glossaries

extension AppModel {
    func manageGlossaries() {
        guard !isShuttingDown else { return }
        pane = .new
        glossariesRequest = UUID()
    }

    /// Read from the folder, so a file edited in another application counts.
    func refreshGlossaries() {
        glossaries = GlossaryStore.all()
        for glossary in unsavedGlossaries.values {
            glossaries.removeAll { $0.name == glossary.name }
            glossaries.append(glossary)
        }
        glossaries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let glossaryName, !glossaries.contains(where: { $0.name == glossaryName }) {
            self.glossaryName = nil
        }
    }

    /// Creates an empty glossary under a free name and returns that name.
    func createGlossary(named wanted: String) throws -> String {
        let glossary = Glossary(name: GlossaryStore.freeName(for: wanted), text: "")
        try GlossaryStore.save(glossary)
        refreshGlossaries()
        return glossary.name
    }

    /// Runs on every keystroke, so the list is patched rather than read again.
    func saveGlossary(_ glossary: Glossary) throws {
        do {
            try GlossaryStore.save(glossary)
            unsavedGlossaries[glossary.name] = nil
            if !hasUnsavedHistory { storageFailure = nil }
        } catch {
            unsavedGlossaries[glossary.name] = glossary
            storageFailure = error.localizedDescription
            throw error
        }
        if let index = glossaries.firstIndex(where: { $0.name == glossary.name }) {
            glossaries[index] = glossary
        } else {
            refreshGlossaries()
        }
    }

    func importGlossary(_ file: URL) throws -> String {
        let glossary = try GlossaryStore.importFile(file)
        refreshGlossaries()
        return glossary.name
    }

    func deleteGlossary(named name: String) throws {
        defer { refreshGlossaries() }
        try GlossaryStore.delete(named: name)
        CourseCorrections.delete(for: name, in: courseCorrectionsFolder)
        readCourseCorrections[name] = nil
        unsavedGlossaries[name] = nil
        if !hasUnsavedHistory { storageFailure = nil }
    }

    /// The glossary the page has chosen, read from disk again so that one
    /// edited elsewhere counts, and the name of one that is no longer there.
    func chosenGlossary() -> (glossary: Glossary?, lost: String?) {
        let chosen = glossaryName
        refreshGlossaries()
        let glossary = glossaryApplies ? glossaries.first { $0.name == glossaryName } : nil
        let lost = (chosen != nil && glossaryApplies && glossary == nil) ? chosen : nil
        return (glossary, lost)
    }

    func lostGlossary(_ name: String) -> String {
        String(
            localized:
                "The glossary \(name) is no longer in your library, so these recordings are transcribed without one."
        )
    }

    /// Exact when a Whisper model is already open and idle; estimated
    /// otherwise, since loading gigabytes of weights for a keystroke is not
    /// worth an exact figure.
    func tokens(in prompt: String) async -> (count: Int, exact: Bool) {
        if let whisper = engine as? WhisperEngine, !stage.isRunning {
            return (await whisper.tokenCount(of: prompt), true)
        }
        return (Glossary.estimatedTokens(of: prompt), false)
    }

    /// Limits what a later window reads back to the glossary, leaving out
    /// everything transcribed before it.
    ///
    /// Earlier text can otherwise trigger a repetition loop, so leaving it out
    /// avoids that risk once the glossary already supplies the vocabulary.
    /// Without a glossary, a window reads nothing from before it either.
    ///
    /// whisper.cpp truncates a glossary longer than its token budget without
    /// telling anyone, so the warning below is the only place the user sees it.
    func limitContextToGlossary(
        _ settings: inout DecodingSettings, of id: Entry.ID, on engine: WhisperEngine
    ) async {
        guard let prompt = settings.prompt else {
            settings.textContext = 0
            return
        }
        let count = await engine.tokenCount(of: prompt)
        settings.textContext = Int32(count + 1)
        guard count > Glossary.tokenBudget else { return }
        let warning = String(
            localized:
                "This glossary uses \(count) tokens and the model reads only the last \(Glossary.tokenBudget), so its first terms are ignored."
        )
        updateEntry(id) { $0.glossaryWarning = warning }
    }

    /// The corrections remembered for a transcript's course.
    func courseCorrections(for entry: Entry) -> [CourseCorrection] {
        entry.glossary.map { courseCorrections(forCourse: $0) } ?? []
    }

    func courseCorrections(forCourse name: String) -> [CourseCorrection] {
        if let read = readCourseCorrections[name] { return read }
        let read = CourseCorrections.all(for: name, in: courseCorrectionsFolder)
        readCourseCorrections[name] = read
        return read
    }

    /// Remembers a replacement for the course of a transcript, for its next ones.
    func remember(_ correction: CourseCorrection, forCourseOf id: Entry.ID) {
        guard let name = entry(id)?.glossary else { return }
        defer { readCourseCorrections[name] = nil }
        do {
            try CourseCorrections.remember(correction, for: name, in: courseCorrectionsFolder)
        } catch {
            report(error)
        }
    }

    func forget(_ correction: CourseCorrection, forCourse name: String) {
        defer { readCourseCorrections[name] = nil }
        do {
            try CourseCorrections.forget(correction, for: name, in: courseCorrectionsFolder)
        } catch {
            report(error)
        }
    }

}
