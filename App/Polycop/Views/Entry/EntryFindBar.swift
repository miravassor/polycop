// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// What Find and Replace holds for one transcript: the text looked for, its
/// results and the one shown, and the replacement.
struct TranscriptFind {
    var isShown = false
    var query = ""
    var matches: [TranscriptSearch.Match] = []
    var index = 0
    var isReplacing = false
    var replacement = ""
    var remembersReplacement = false

    var current: TranscriptSearch.Match? {
        matches.indices.contains(index) ? matches[index] : nil
    }

    /// Looks for the query again. Starting over shows the first result;
    /// otherwise the one shown stays, as long as there still is one.
    mutating func refresh(in paragraphs: [Transcript.Paragraph], startingOver: Bool) {
        matches = TranscriptSearch.matches(in: paragraphs, query: query)
        index = startingOver ? 0 : min(index, max(0, matches.count - 1))
    }

    /// Shows the next or the previous result, going round at either end.
    mutating func step(forward: Bool) {
        guard !matches.isEmpty else { return }
        index = (index + (forward ? 1 : matches.count - 1)) % matches.count
    }

    mutating func close() {
        isShown = false
        query = ""
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
            Text(
                find.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? ""
                    : find.matches.isEmpty
                        ? "No results" : "\(find.index + 1) of \(find.matches.count)"
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize()
            Button {
                navigate(false)
            } label: {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(find.matches.isEmpty)
            .accessibilityLabel("Previous search result")
            Button {
                navigate(true)
            } label: {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut("g")
            .disabled(find.matches.isEmpty)
            .accessibilityLabel("Next search result")
            Toggle("Replace", isOn: $find.isReplacing)
                .toggleStyle(.checkbox)
            Button {
                find.close()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close search")
        }
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
    }
}
