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
                unfiledSection
                foldersSection
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
                LibraryWarnings(model: model)
                if selected.count > 1 {
                    SelectionView(
                        model: model, selected: selected,
                        move: { ids in
                            destinationFolder = nil
                            moving = ids
                        },
                        remove: { removing = $0 })
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
            MoveTranscriptsSheet(
                model: model, moving: $moving, destinationFolder: $destinationFolder,
                opened: { expandedFolders.insert($0) })
        }
        .minimumSize(width: 860, height: 600)
        .disabled(model.isShuttingDown)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isShuttingDown else { return false }
            model.transcribe(urls)
            return !urls.isEmpty
        }
    }

    /// The transcripts in no folder, or the whole library before there is one.
    private var unfiledSection: some View {
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
    }

    /// Each folder, opened or closed, with its transcripts.
    private var foldersSection: some View {
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

#Preview {
    ContentView(model: AppModel())
}
