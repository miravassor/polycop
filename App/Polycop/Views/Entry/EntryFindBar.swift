// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// What Find and Replace holds for one transcript: the text looked for, its
/// results and the one shown, and the replacement.
struct TranscriptFind {
    var isShown = false
    var query = ""
    var matches: [TranscriptSearch.Match] = []
    var index = 0
    /// False once an edit has taken the result shown away. The result at that
    /// place waits for the reader to step to it, so that typing never makes
    /// the page scroll to another paragraph.
    var showsCurrent = true
    var isReplacing = false
    var replacement = ""
    var remembersReplacement = false
    /// The length of each paragraph searched, to follow a result that an edit
    /// before it has moved.
    private var lengths: [Int] = []

    var current: TranscriptSearch.Match? {
        showsCurrent && matches.indices.contains(index) ? matches[index] : nil
    }

    /// Looks for the query again. Starting over shows the first result.
    /// Otherwise an edit that adds or removes no result keeps the one shown;
    /// one that does keeps the place rather than the position.
    mutating func refresh(in paragraphs: [Transcript.Paragraph], startingOver: Bool) {
        let previous = matches
        let previousLengths = lengths
        matches = TranscriptSearch.matches(in: paragraphs, query: query)
        lengths = paragraphs.map { ($0.text as NSString).length }
        guard !startingOver else {
            index = 0
            showsCurrent = true
            return
        }
        guard matches.count != previous.count, previous.indices.contains(index) else {
            index = min(index, max(0, matches.count - 1))
            return
        }
        let place = previous[index]
        // Text taken out before the result moves it back by as much.
        let shrunk =
            previousLengths.indices.contains(place.paragraph)
                && lengths.indices.contains(place.paragraph)
            ? max(0, previousLengths[place.paragraph] - lengths[place.paragraph]) : 0
        index = first(from: place.paragraph, at: place.range.location - shrunk) ?? 0
        if matches.indices.contains(index), matches[index] != place { showsCurrent = false }
    }

    /// Shows the next or the previous result, going round at either end. The
    /// first step after an edit took the result away shows the one waiting.
    mutating func step(forward: Bool) {
        guard !matches.isEmpty else { return }
        if showsCurrent || !forward {
            index = (index + (forward ? 1 : matches.count - 1)) % matches.count
        }
        showsCurrent = true
    }

    /// After a replacement, shows the first result past it: one that still
    /// matches, as when only case or accents changed, is not shown again.
    mutating func showFirst(
        after match: TranscriptSearch.Match, replacedBy replacement: String,
        in paragraphs: [Transcript.Paragraph]
    ) {
        refresh(in: paragraphs, startingOver: true)
        let end = match.range.location + (replacement as NSString).length
        index = first(from: match.paragraph, at: end) ?? 0
    }

    mutating func close() {
        isShown = false
        query = ""
    }

    /// The first result at or after a place in the text.
    private func first(from paragraph: Int, at location: Int) -> Int? {
        matches.firstIndex {
            $0.paragraph > paragraph || ($0.paragraph == paragraph && $0.range.location >= location)
        }
    }
}

/// The find field above a transcript, with its replace row when asked for.
struct EntryFindBar: View {
    let model: AppModel
    let entry: Entry
    let isRunning: Bool
    @Binding var find: TranscriptFind
    var isFocused: FocusState<Bool>.Binding
    /// Shows the next result when true, the previous one when false.
    let navigate: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            findRow
            if find.isReplacing { replaceRow }
        }
    }

    private var findRow: some View {
        HStack(spacing: 12) {
            TextField("Find in your text", text: $find.query)
                .textFieldStyle(.roundedBorder)
                .focused(isFocused)
                .onSubmit { navigate(true) }
                .onExitCommand { find.close() }
            Text(position)
                .font(.caption).foregroundStyle(.secondary).fixedSize()
            iconButton("Previous search result", symbol: "chevron.up") { navigate(false) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(find.matches.isEmpty)
            iconButton("Next search result", symbol: "chevron.down") { navigate(true) }
                .keyboardShortcut("g")
                .disabled(find.matches.isEmpty)
            Toggle("Replace", isOn: $find.isReplacing)
                .toggleStyle(.checkbox)
            iconButton("Close search", symbol: "xmark") { find.close() }
        }
    }

    private func iconButton(
        _ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
        }
        .help(title)
    }

    /// Where the reader is among the results, or how many there are while
    /// none is shown.
    private var position: LocalizedStringKey {
        if find.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        if find.matches.isEmpty { return "No results" }
        guard find.current != nil else {
            return find.matches.count == 1 ? "1 result" : "\(find.matches.count) results"
        }
        return "\(find.index + 1) of \(find.matches.count)"
    }

    /// Replacement is literal, while finding ignores case and accents, so every
    /// spelling of a misheard word is replaced by the same correction.
    private var replaceRow: some View {
        HStack(spacing: 12) {
            TextField("Replace with", text: $find.replacement)
                .textFieldStyle(.roundedBorder)
                .onSubmit(replaceCurrentMatch)
            Button("Replace", action: replaceCurrentMatch)
                .disabled(find.current == nil || isRunning)
            Button("Replace All") {
                if find.remembersReplacement {
                    model.remember(
                        CourseCorrection(
                            text: find.query.trimmingCharacters(in: .whitespacesAndNewlines),
                            replacement: find.replacement),
                        forCourseOf: entry.id)
                }
                model.replace(entry.id, matches: find.matches, with: find.replacement)
            }
            .disabled(find.matches.isEmpty || isRunning)
            .help("Replace every result. Undo Last Correction takes them all back.")
            if let course = entry.glossary {
                Toggle("Remember for \(course)", isOn: $find.remembersReplacement)
                    .toggleStyle(.checkbox)
                    .help("Replace All also corrects this course's next transcripts.")
            }
        }
    }

    private func replaceCurrentMatch() {
        guard let current = find.current else { return }
        model.replace(entry.id, matches: [current], with: find.replacement)
        guard let paragraphs = model.entry(entry.id)?.paragraphs else { return }
        find.showFirst(after: current, replacedBy: find.replacement, in: paragraphs)
    }
}

private struct EntryFindBarPreview: View {
    // Constructed once for the preview, using isolated folders rather than the user's library.
    @State private var model: AppModel
    @State private var find = TranscriptFind(
        isShown: true, query: "Freud",
        matches: [
            TranscriptSearch.Match(paragraph: 0, range: NSRange(location: 0, length: 5)),
            TranscriptSearch.Match(paragraph: 1, range: NSRange(location: 12, length: 5)),
        ],
        isReplacing: true, replacement: "Froid")
    @FocusState private var isFocused: Bool
    private let entry = Entry(
        recording: URL(filePath: "/tmp/lecture.m4a"),
        modelFile: ModelCatalog.recommended.id,
        glossary: Glossary(name: "Psychologie", text: ""),
        skipsSilence: false, subtitles: false)

    init() {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        _model = State(
            initialValue: AppModel(
                history: folder.appending(path: "History"),
                glossaries: folder.appending(path: "Glossaries"),
                models: folder.appending(path: "Models"),
                playbackCopies: folder.appending(path: "Copies"),
                defaults: MemoryDefaults()))
    }

    var body: some View {
        EntryFindBar(
            model: model, entry: entry, isRunning: false, find: $find, isFocused: $isFocused,
            navigate: { find.step(forward: $0) }
        )
        .padding(Spacing.sheet)
        .frame(width: 560)
    }
}

#Preview {
    EntryFindBarPreview()
}
