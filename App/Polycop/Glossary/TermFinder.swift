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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Find Terms in Documents").font(.title2.weight(.semibold))
                Text("BETA")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            .padding([.horizontal, .top], 24)
            // Grouped rows as the other sheets: what is read, then what was
            // found, to trim before adding.
            Form {
                documents
                Section("Or Paste Text") {
                    TextEditor(text: $pasted)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(height: 56)
                        .accessibilityLabel("Text to read")
                }
                results
            }
            .formStyle(.grouped)
            HStack(spacing: 12) {
                Button("Find Terms", systemImage: "magnifyingglass") { find() }
                    .disabled(searching || (files.isEmpty && pasted.isEmpty))
                if searching { ProgressView().controlSize(.small) }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .notice(.orange)
                        .lineLimit(2)
                }
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
            .padding(24)
        }
        .onDisappear { search?.cancel() }
        .frame(width: 640, height: 640)
        .fileImporter(
            isPresented: $choosing, allowedContentTypes: Documents.readable,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let chosen):
                // Read at once: choosing documents is asking for their terms.
                files += chosen.filter { !files.contains($0) }
                find()
            case .failure(let error): problem = error.localizedDescription
            }
        }
    }

    /// The documents chosen, by name, with Add on the title line as the
    /// recordings waiting have.
    private var documents: some View {
        Section {
            if files.isEmpty {
                Text("Slides, a syllabus or your notes: PDF, Word, RTF, Markdown or plain text.")
                    .foregroundStyle(.secondary)
            }
            ForEach(files, id: \.self) { file in
                HStack(spacing: 8) {
                    Label(file.lastPathComponent, systemImage: "doc.text")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button {
                        files.removeAll { $0 == file }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(file.lastPathComponent)")
                }
            }
        } header: {
            HStack {
                Text("Documents")
                Spacer()
                Button("Add…", systemImage: "plus") { choosing = true }
                    .buttonBorderShape(.capsule)
            }
        } footer: {
            Text("Read for their words only; nothing is copied into Polycop.")
        }
    }

    private var results: some View {
        Section {
            TextEditor(text: $found)
                .font(.body)
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .accessibilityLabel("Terms found")
        } header: {
            HStack {
                Text("Terms Found")
                Spacer()
                if !terms.isEmpty {
                    Text("\(terms.count)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(
                "Remove what the lecturer will not say. The last lines weigh most: the model reads the end of a glossary."
            )
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
