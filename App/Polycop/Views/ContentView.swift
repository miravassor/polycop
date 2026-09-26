// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ContentView: View {
    let model: AppModel
    /// What the sidebar has selected. Several rows can be selected with shift
    /// or command, to file or remove them together; one of them is also what
    /// the window shows, which is why the pane follows this.
    @State private var selection: Set<AppModel.Pane> = [.new]
    @State private var removing: [Entry.ID] = []
    @State private var moving: [Entry.ID] = []
    @State private var destinationFolder: UUID?
    @State private var namingFolder = false
    @State private var renamedFolder: UUID?
    @State private var folderName = ""
    @State private var expandedFolders: Set<UUID> = []
    @State private var highlighted: UUID?
    @State private var reverting: Entry?
    @State private var highlightsUnfiled = false
    @State private var importingTranscript = false

    private var unfiled: [Entry] {
        let known = Set(model.folders.map(\.id))
        return model.entries.filter { $0.folderID.map { !known.contains($0) } ?? true }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("New Transcription", systemImage: "plus")
                    .fontWeight(.medium)
                    .padding(.vertical, 5)
                    .tag(AppModel.Pane.new)
                Section {
                    if unfiled.isEmpty {
                        Text("Nothing outside a folder")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(unfiled) { entry in row(entry) }
                } header: {
                    Text(model.folders.isEmpty ? "Library" : "Unfiled")
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            highlightsUnfiled ? Color.accentColor.opacity(0.25) : .clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contextMenu { newFolder }
                        .dropDestination(for: String.self) { items, _ in
                            drop(items, into: nil)
                        } isTargeted: {
                            highlightsUnfiled = $0
                        }
                }
                Section {
                    if model.folders.isEmpty {
                        Text("No folders yet").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.folders) { folder in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedFolders.contains(folder.id) },
                                set: {
                                    if $0 {
                                        expandedFolders.insert(folder.id)
                                    } else {
                                        expandedFolders.remove(folder.id)
                                    }
                                }
                            )
                        ) {
                            let entries = model.entries.filter { $0.folderID == folder.id }
                            if entries.isEmpty {
                                Text("Empty folder").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(entries) { entry in row(entry) }
                        } label: {
                            Label(folder.name, systemImage: "folder")
                                .lineLimit(1)
                                .padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    highlighted == folder.id
                                        ? Color.accentColor.opacity(0.25) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .dropDestination(for: String.self) { items, _ in
                                    drop(items, into: folder.id)
                                } isTargeted: {
                                    highlighted = $0 ? folder.id : nil
                                }
                                .contextMenu {
                                    Button("Rename Folder…") {
                                        renamedFolder = folder.id
                                        folderName = folder.name
                                        namingFolder = true
                                    }
                                    Button("Delete Empty Folder", role: .destructive) {
                                        attempt { try model.removeFolder(folder.id) }
                                    }
                                    .disabled(model.entries.contains { $0.folderID == folder.id })
                                    Divider()
                                    newFolder
                                }
                        }
                    }
                } header: {
                    // The button sits on the header's own line: a bordered style
                    // and a body sized symbol both stand away from a sidebar
                    // title, which is small and secondary.
                    HStack(alignment: .firstTextBaseline) {
                        Text("Folders")
                        Spacer(minLength: 8)
                        Button(action: startNewFolder) {
                            Image(systemName: "folder.badge.plus")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("New folder")
                        .accessibilityLabel("New folder")
                        // Clear of the edge of the sidebar, where the scroller runs.
                        .padding(.trailing, 6)
                    }
                    .contextMenu { newFolder }
                }
            }
            .listStyle(.sidebar)
            .contextMenu { newFolder }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            .safeAreaInset(edge: .bottom) {
                Label("Always stored on this Mac", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            VStack(spacing: 0) {
                if let failure = model.storageFailure {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "Changes could not be stored", systemImage: "exclamationmark.triangle"
                        )
                        .font(.callout.weight(.semibold))
                        Text(failure)
                            .font(.callout)
                            .textSelection(.enabled)
                        Button("Retry Saving") { _ = model.retrySavingHistory() }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    Divider()
                }
                if let warning = model.libraryWarning {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "Part of your library could not be read",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.callout.weight(.semibold))
                        Text(warning)
                            .font(.callout)
                            .textSelection(.enabled)
                        if model.foldersAreDamaged {
                            Text(
                                "Folders cannot be created, renamed or deleted until the file that lists them is repaired or removed, so that nothing writes over it."
                            )
                            .font(.callout)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    Divider()
                }
                if selected.count > 1 {
                    chosen
                } else if case .entry(let id) = model.pane, let entry = model.entry(id) {
                    EntryView(model: model, entry: entry)
                        .id(id)
                } else {
                    NewTranscriptionView(model: model)
                }
            }
            // The detail column asks for a minimum of its own; this is the one
            // its pages had.
            .minimumSize(width: 360, height: 450)
        }
        .onChange(of: selection) { _, chosen in
            // Several rows are a selection to act on, not a page to show, so
            // the window only follows a single one.
            guard chosen.count == 1, let only = chosen.first, only != model.pane else { return }
            model.pane = only
        }
        .onChange(of: model.pane) { _, pane in
            guard selection != [pane] else { return }
            selection = [pane]
        }
        .task(id: model.folderRequest) {
            guard model.folderRequest != nil else { return }
            model.folderRequest = nil
            startNewFolder()
        }
        .task(id: model.transcriptImportRequest) {
            guard model.transcriptImportRequest != nil else { return }
            model.transcriptImportRequest = nil
            importingTranscript = true
        }
        .sheet(isPresented: $importingTranscript) { TranscriptImportView(model: model) }
        .alert(renamedFolder == nil ? "New folder" : "Rename folder", isPresented: $namingFolder) {
            TextField("Folder name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button(renamedFolder == nil ? "Create" : "Rename") {
                attempt {
                    if let renamedFolder {
                        try model.renameFolder(renamedFolder, to: folderName)
                    } else {
                        expandedFolders.insert(try model.createFolder(named: folderName))
                    }
                }
            }
            .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Folders organize your library. Audio files stay where they are.")
        }
        .confirmationDialog(
            removing.count > 1
                ? "Remove \(removing.count) transcripts from the library?"
                : "Remove this transcript from the library?",
            isPresented: Binding(
                get: { !removing.isEmpty }, set: { if !$0 { removing = [] } }
            )
        ) {
            Button(
                removing.count > 1 ? "Remove Transcripts" : "Remove Transcript", role: .destructive
            ) {
                model.removeEntries(removing)
                removing = []
            }
        } message: {
            Text(
                removing.count > 1
                    ? "The transcripts and their corrections will be removed. Audio files and exports are kept."
                    : "The transcript and its corrections will be removed. Audio files and exports are kept."
            )
        }
        .confirmationDialog(
            "Throw away every correction of this transcript?",
            isPresented: Binding(get: { reverting != nil }, set: { if !$0 { reverting = nil } })
        ) {
            Button("Revert to Original", role: .destructive) {
                if let reverting { model.revert(reverting.id) }
                reverting = nil
            }
        } message: {
            Text(
                "The text goes back to what the engine wrote. Files already exported stay as they are, and a correction can be stepped back one at a time instead."
            )
        }
        .sheet(isPresented: Binding(get: { !moving.isEmpty }, set: { if !$0 { moving = [] } })) {
            VStack(alignment: .leading, spacing: 20) {
                Text(moving.count > 1 ? "Move transcripts" : "Move transcript")
                    .font(.title2.weight(.semibold))
                Text(
                    moving.count > 1
                        ? "\(moving.count) transcripts"
                        : (moving.first.flatMap { model.entry($0)?.name } ?? "")
                )
                .lineLimit(2)
                .truncationMode(.middle)
                Picker("Folder", selection: $destinationFolder) {
                    Text("Unfiled").tag(UUID?.none)
                    ForEach(model.folders) { folder in
                        Text(folder.name).tag(UUID?.some(folder.id))
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { moving = [] }
                        .keyboardShortcut(.cancelAction)
                    Button("Move") {
                        for id in moving { model.moveEntry(id, to: destinationFolder) }
                        if let destinationFolder { expandedFolders.insert(destinationFolder) }
                        moving = []
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 380)
        }
        .minimumSize(width: 860, height: 600)
        .disabled(model.isShuttingDown)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isShuttingDown else { return false }
            model.transcribe(urls)
            return !urls.isEmpty
        }
    }

    /// Several transcripts selected: the window shows what they are and what
    /// can be done to all of them, rather than one of them at random.
    private var chosen: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(selected.count) transcripts selected")
                .font(.title2.weight(.semibold))
            Text(
                "Shift or command click to change the selection. Drag them onto a folder to file them."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Move to Folder…") {
                    destinationFolder = nil
                    moving = selected
                }
                Button("Remove from Folder") {
                    for id in selected { model.moveEntry(id, to: nil) }
                }
                .disabled(!selected.contains { model.entry($0)?.folderID != nil })
                Button("Remove from Library…", role: .destructive) { removing = selected }
            }
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var newFolder: some View {
        Button("New Folder…", action: startNewFolder)
            .disabled(model.foldersAreDamaged)
    }

    private func startNewFolder() {
        renamedFolder = nil
        folderName = ""
        namingFolder = true
    }

    private func row(_ entry: Entry) -> some View {
        let targets = targets(of: entry)
        return EntryRow(entry: entry, stage: entry.id == model.busyEntry ? model.stage : nil)
            .tag(AppModel.Pane.entry(entry.id))
            .draggable(targets.map(\.uuidString).joined(separator: "\n"))
            .contextMenu {
                Button("Move to Folder…") {
                    destinationFolder = entry.folderID
                    moving = targets
                }
                if targets.contains(where: { model.entry($0)?.folderID != nil }) {
                    Button("Remove from Folder") {
                        for id in targets { model.moveEntry(id, to: nil) }
                    }
                }
                newFolder
                // What belongs to one transcript is offered for one: undoing or
                // reverting several at once is not what a right click means.
                if targets.count == 1 {
                    Divider()
                    Button("Undo Last Correction") { model.undo(entry.id) }
                        .disabled(!model.canUndo(entry.id) || entry.id == model.busyEntry)
                    Button("Revert to Original…") { reverting = entry }
                        .disabled(!entry.isEdited || entry.id == model.busyEntry)
                    Button("Duplicate Transcript") { model.duplicate(entry.id) }
                        .disabled(entry.paragraphs.isEmpty || entry.id == model.busyEntry)
                }
                Divider()
                Button("Remove from Library…", role: .destructive) { removing = targets }
                    .disabled(targets == [model.busyEntry])
            }
    }

    /// The transcripts an action on this row applies to: the whole selection
    /// when the row is part of it, and the row alone otherwise, as the Finder
    /// behaves.
    private func targets(of entry: Entry) -> [Entry.ID] {
        guard selection.contains(.entry(entry.id)), selected.count > 1 else { return [entry.id] }
        return selected
    }

    /// The transcripts selected, in the order the list shows them.
    private var selected: [Entry.ID] {
        model.entries.map(\.id).filter { selection.contains(.entry($0)) }
    }

    /// A transcript dragged onto a folder, or onto the unfiled section to leave
    /// one. What travels is the identifier: a recording dragged in from the
    /// Finder carries a path, which no entry answers to, and is refused.
    private func drop(_ items: [String], into folder: UUID?) -> Bool {
        let moved = items.flatMap { $0.split(separator: "\n").map(String.init) }
        guard model.moveEntries(moved, to: folder) else { return false }
        if let folder { expandedFolders.insert(folder) }
        return true
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { model.report(error) }
    }
}

private struct EntryRow: View {
    let entry: Entry
    let stage: AppModel.Stage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            status
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch entry.state {
        case .waiting:
            Text("Waiting")
        case .running:
            switch stage {
            case .transcribing(let progress): Text("Transcribing · \(percent(progress))")
            case .repairing(let progress): Text("Repeats · \(percent(progress))")
            case .paused(let progress): Text("Paused · \(percent(progress))")
            case .stopping: Text("Stopping")
            default: Text("Preparing")
            }
        case .finished:
            // Busy while finished only when its repeats are transcribed again.
            switch stage {
            case .repairing(let progress): Text("Repeats · \(percent(progress))")
            case nil: Text("Ready to review")
            default: Text("Preparing")
            }
        case .stopped:
            Text("Stopped before the end")
        case .failed:
            Label("Failed", systemImage: "exclamationmark.circle")
        }
    }
}

func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
}

#Preview {
    ContentView(model: AppModel())
}

/// A smallest size given without measuring the content. SwiftUI asks the
/// window, and each column of the split view, for its minimum after every
/// change; a frame with a minimum would measure the whole page to answer.
private struct MinimumSize: Layout {
    let size: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(
            width: max(size.width, proposal.width ?? size.width),
            height: max(size.height, proposal.height ?? size.height))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }

    // Without these, a stack asking for the alignment guides would have the
    // page placed, and so measured, to read them.
    func explicitAlignment(
        of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) -> CGFloat? { nil }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) -> CGFloat? { nil }
}

extension View {
    fileprivate func minimumSize(width: CGFloat, height: CGFloat) -> some View {
        MinimumSize(size: CGSize(width: width, height: height)) { self }
    }
}
