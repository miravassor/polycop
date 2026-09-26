// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Course glossaries: one term per line, saved as it is typed.
struct GlossaryEditor: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var corrections: [CourseCorrection] = []
    @State private var text = ""
    @State private var count = 0
    @State private var exact = false
    @State private var problem: String?
    @State private var importing = false
    @State private var naming = false
    @State private var newName = ""
    @State private var confirmingDeletion = false
    @State private var findingTerms = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Glossary").font(.title2.weight(.semibold))
            Text(
                "Optional spelling guidance for names, authors and specialist terms. Keep the words most likely to be spoken; a glossary does not guarantee they will be recognized."
            )
            .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                courses
                terms
            }
            if let problem {
                Label(problem, systemImage: "xmark.octagon")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Divider()
            HStack {
                Button("Show in Finder") { reveal() }
                    .disabled(selection == nil)
                Spacer()
                // No Return shortcut: Return starts the next term.
                Button("Done") { if save() { dismiss() } }
                    .keyboardShortcut(.cancelAction)
                Button("Use This Glossary") {
                    if save() {
                        model.glossaryName = selection
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }
        }
        .padding(24)
        .frame(width: 700, height: 500)
        .interactiveDismissDisabled(problem != nil)
        .sheet(isPresented: $findingTerms) {
            TermFinder(attested: Set(Glossary.terms(in: text)), add: append)
        }
        .onChange(of: text) { save() }
        .task(id: text) { await recount() }
        .onAppear {
            model.refreshGlossaries()
            select(model.glossaryName ?? model.glossaries.first?.name)
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let files):
                if let file = files.first { attempt { try select(model.importGlossary(file)) } }
            case .failure(let error): problem = error.localizedDescription
            }
        }
        .confirmationDialog("Move this glossary to the Trash?", isPresented: $confirmingDeletion) {
            Button("Move to Trash", role: .destructive) { attempt { try delete() } }
        } message: {
            Text(selection ?? "")
        }
        .alert("New course", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") {
                attempt { try select(model.createGlossary(named: newName)) }
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private var courses: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(model.glossaries, selection: Binding(get: { selection }, set: { select($0) })) {
                Text($0.name)
            }
            .listStyle(.bordered)
            HStack {
                Button("New…") { naming = true }
                Button("Import…") { importing = true }
                Button("Delete…") { confirmingDeletion = true }
                    .disabled(selection == nil)
            }
        }
        .frame(width: 200)
    }

    @ViewBuilder
    private var terms: some View {
        if selection == nil {
            Text("Create a course, or import a text file with one term per line.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("One term per line: authors, concepts, words to spell as they are taught.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.body)
                    .autocorrectionDisabled()
                    .border(.separator)
                    .accessibilityLabel("Glossary terms")
                if count > 0 {
                    counter
                }
                HStack(spacing: 12) {
                    Button("Terms from Documents…") { findingTerms = true }
                    Text("BETA").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                if !corrections.isEmpty { correctionList }
            }
            .task(id: selection) { reloadCorrections() }
        }
    }

    /// Replacements remembered from Replace All, applied to new transcripts.
    private var correctionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Corrections applied to new transcripts").font(.headline)
            ForEach(corrections, id: \.self) { correction in
                HStack(spacing: 8) {
                    Text("\(correction.find) → \(correction.replacement)")
                        .textSelection(.enabled)
                    Spacer()
                    Button("Forget") {
                        guard let selection else { return }
                        model.forget(correction, forCourse: selection)
                        reloadCorrections()
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func reloadCorrections() {
        corrections = selection.map { model.courseCorrections(forCourse: $0) } ?? []
    }

    @ViewBuilder
    private var counter: some View {
        let over = count > Glossary.tokenBudget
        Group {
            if exact {
                Text("Whisper: \(count) of \(Glossary.tokenBudget) tokens")
            } else {
                Text("Whisper: about \(count) of \(Glossary.tokenBudget) tokens")
            }
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(over ? .orange : .secondary)
        if over {
            Text(
                "Whisper reads only the last \(Glossary.tokenBudget) tokens, so the first terms would be ignored. MOSS uses the terms as hotwords."
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    private func select(_ name: String?) {
        guard save() else { return }
        selection = name
        text = model.glossaries.first { $0.name == name }?.text ?? ""
    }

    @discardableResult
    private func save() -> Bool {
        guard let selection else { return true }
        do {
            try model.saveGlossary(Glossary(name: selection, text: text))
            problem = nil
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    /// Keeps the order the finder gave: the terms it trusts most go last,
    /// where whisper.cpp reads them even when a glossary is too long.
    private func append(_ terms: [String]) {
        let existing = Glossary.terms(in: text)
        let known = Set(existing.map { $0.lowercased() })
        let added = terms.filter { !known.contains($0.lowercased()) }
        guard !added.isEmpty else { return }
        text = (existing + added).joined(separator: "\n")
        save()
    }

    private func delete() throws {
        guard let selection else { return }
        try model.deleteGlossary(named: selection)
        self.selection = nil
        select(model.glossaries.first?.name)
    }

    /// Errors show here, where the user is looking, not under the sheet.
    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Counts what is actually sent: the sentence, not the raw list.
    private func recount() async {
        guard text.utf8.count <= GlossaryStore.largestImport,
            let prompt = Glossary(name: "", text: text).prompt(in: model.language)
        else {
            count = 0
            return
        }
        let result = await model.tokens(in: prompt)
        guard !Task.isCancelled else { return }
        count = result.count
        exact = result.exact
    }

    private func reveal() {
        guard let selection else { return }
        NSWorkspace.shared.activateFileViewerSelecting([GlossaryStore.location(of: selection)])
    }
}
