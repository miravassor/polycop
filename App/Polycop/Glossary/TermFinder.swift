// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Builds a glossary from course material.
///
/// Files are read only here; their text is scanned for names and acronyms,
/// then discarded. Only the terms the user keeps are added to the glossary,
/// and the source material never enters the app's own folders.
struct TermFinder: View {
    /// Terms already written by hand, believed even on a page in capitals.
    let attested: Set<String>
    let add: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var pasted = ""
    @State private var found = ""
    @State private var choosing = false
    @State private var searching = false
    @State private var search: Task<Void, Never>?
    @State private var problem: String?

    private var terms: [String] { Glossary.terms(in: found) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Terms from course material").font(.title2.weight(.semibold))
                Text("BETA").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(
                "Slides, a syllabus or your notes: PDF, Word, RTF, Markdown or plain text. They are read for their words only and nothing is copied into the app."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            sources
            Divider()
            results
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to Glossary") {
                    add(terms)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(terms.isEmpty || searching)
            }
        }
        .onDisappear { search?.cancel() }
        .padding(24)
        .frame(width: 640, height: 600)
        .fileImporter(
            isPresented: $choosing, allowedContentTypes: Documents.readable,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let chosen): files = chosen
            case .failure(let error): problem = error.localizedDescription
            }
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button("Choose Files…") { choosing = true }
                if !files.isEmpty {
                    Text(files.map(\.lastPathComponent).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Text("Or paste text").font(.callout)
            TextEditor(text: $pasted)
                .font(.body)
                .frame(height: 72)
                .border(.separator)
                .accessibilityLabel("Text to read")
            HStack(spacing: 12) {
                Button("Find Terms") { find() }
                    .disabled(searching || (files.isEmpty && pasted.isEmpty))
                if searching { ProgressView().controlSize(.small) }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Terms found").font(.headline)
                Spacer()
                if !terms.isEmpty {
                    Text("\(terms.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(
                "Remove what the lecturer will not say. The last lines matter most: the model reads the end of a glossary."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $found)
                .font(.body)
                .autocorrectionDisabled()
                .border(.separator)
                .accessibilityLabel("Terms found")
        }
    }

    private func find() {
        searching = true
        problem = nil
        let chosen = files
        let text = pasted
        search = Task {
            defer { searching = false }
            do {
                var pages: [String] = []
                var bytes = text.utf8.count
                guard bytes <= Documents.largestText else {
                    throw DocumentError.tooLarge(URL(filePath: "Pasted text"))
                }
                for file in chosen {
                    try Task.checkCancellation()
                    let read = try await Documents.pages(of: file)
                    bytes += read.reduce(0) { $0 + $1.utf8.count }
                    guard bytes <= Documents.largestText else { throw DocumentError.tooLarge(file) }
                    pages += read
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pages += Documents.blocks(of: text)
                }
                let candidates = await Terms.candidates(in: pages, attested: attested)
                try Task.checkCancellation()
                found = candidates.joined(separator: "\n")
                if candidates.isEmpty {
                    problem = String(localized: "No names or specialist terms were found.")
                }
            } catch is CancellationError {
                return
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
