// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ContentView: View {
    let model: AppModel
    /// What the sidebar has selected. Several rows can be selected with shift
    /// or command, to file or remove them together; one of them is also what
    /// the window shows, which is why the pane follows this.
    @State private var selection: Set<AppModel.Pane>
    @State private var removing: [Entry.ID] = []
    @State private var moving: [Entry.ID] = []
    @State private var destinationFolder: UUID?
    @State private var namingFolder = false
    @State private var renamedFolder: UUID?
    @State private var folderName = ""
    @State private var renamedEntry: Entry.ID?
    @State private var entryName = ""
    @State private var highlighted: UUID?
    @State private var reverting: Entry?
    @State private var highlightsUnfiled = false
    @State private var importingTranscript = false

    private var layout: WindowLayout { model.layout }

    init(model: AppModel) {
        self.model = model
        _selection = State(initialValue: [model.pane])
    }

    /// The narrowest page: the player bar and the page margins around it. A
    /// window narrower than its sidebars folds the inspector first, then the
    /// library, so split screen can reach half of any display.
    static let pageMinimumWidth: CGFloat = PlayerBar.narrowest + 2 * Spacing.page
    /// The library shown or hidden.
    private var columns: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { layout.isLibraryShown ? .automatic : .detailOnly },
            set: { layout.isLibraryShown = $0 != .detailOnly })
    }
    /// The margin macOS 26 leaves outside the floating sidebar platter, which
    /// the inspector on the trailing edge does not have.
    static var libraryInset: CGFloat {
        if #available(macOS 26, *) { PlayerBar.foot } else { 0 }
    }
    /// The library's widths: paired with the inspector's so that, with the
    /// floating sidebar's leading margin included, both side columns take the
    /// same room from the window edges and keep the middle page centred.
    static var libraryWidths: ClosedRange<CGFloat> {
        let bounds = EntryView.inspectorWidths
        return (bounds.lowerBound - libraryInset)...(bounds.upperBound - libraryInset)
    }
    static var idealLibraryWidth: CGFloat {
        EntryView.idealInspectorWidth - libraryInset
    }

    private var maxLibraryWidth: CGFloat {
        layout.isResettingSize ? Self.idealLibraryWidth : layout.maxLibraryColumnWidth
    }

    var body: some View {
        // For RedrawTests, in the test host only.
        let _ = Redraws.count(.window, in: model)
        NavigationSplitView(columnVisibility: columns) {
            List(selection: $selection) {
                Label("New Transcription", systemImage: "plus")
                    .fontWeight(.medium)
                    .padding(.vertical, 5)
                    .tag(AppModel.Pane.new)
                unfiledSection
                foldersSection
                RecentlyDeletedSection(model: model)
            }
            .listStyle(.sidebar)
            .contextMenu { libraryMenu }
            // Keep the stored width balanced with the inspector while letting narrow windows
            // bound the sidebar so the page never shrinks below `pageMinimumWidth`.
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                layout.recordLibraryWidth($0)
            }
            .navigationSplitViewColumnWidth(
                min: Self.libraryWidths.lowerBound,
                ideal: min(CGFloat(layout.libraryWidth), maxLibraryWidth),
                max: maxLibraryWidth
            )
        } detail: {
            Group {
                if selected.count > 1 {
                    SelectionView(
                        model: model, selected: selected,
                        move: { ids in
                            destinationFolder = nil
                            moving = ids
                        },
                        remove: { removing = $0 }
                    )
                    .libraryWarnings(model)
                } else if let page = UnavailableRecordPage(model: model) {
                    page.libraryWarnings(model)
                } else if case .entry(let id) = model.pane, let entry = model.entry(id) {
                    EntryView(
                        model: model, entry: entry
                    )
                    .id(id)
                } else {
                    NewTranscriptionView(model: model)
                }
            }
            // The detail column asks for a minimum of its own: the player
            // under the text, and the page's margins.
            .minimumSize(width: Self.pageMinimumWidth, height: 450)
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
        .background { PictureInPictureSource(model: model) }
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
                        layout.openFolders.insert(try model.createFolder(named: folderName))
                    }
                }
            }
            .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Folders organize your library. Audio files stay where they are.")
        }
        .modifier(RenameAlert(renamed: $renamedEntry, name: $entryName, model: model))
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
                    ? "They move to Recently Deleted, with their corrections, for 30 days. Audio files and exports are kept."
                    : "It moves to Recently Deleted, with its corrections, for 30 days. Audio files and exports are kept."
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
                opened: { layout.openFolders.insert($0) })
        }
        .minimumSize(width: Self.pageMinimumWidth, height: 600)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            layout.windowWidth = Double($0)
        }
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
            let entries = model.entries(in: nil)
            if entries.isEmpty, model.unavailable(in: nil).isEmpty,
                model.unidentifiedFiles.isEmpty
            {
                emptyNote("Nothing outside a folder")
            }
            UnavailableRows(model: model, folder: nil)
            ForEach(entries) { entry in row(entry) }
        } header: {
            Text(model.folders.isEmpty ? "Library" : "Unfiled")
                .dropTargetHighlight(highlightsUnfiled)
                .contextMenu { libraryMenu }
                .dropDestination(for: DraggedTranscripts.self) { items, _ in
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
                emptyNote("No folders yet")
            }
            ForEach(model.folders) { folder in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { layout.openFolders.contains(folder.id) },
                        set: {
                            if $0 {
                                layout.openFolders.insert(folder.id)
                            } else {
                                layout.openFolders.remove(folder.id)
                            }
                        }
                    )
                ) {
                    let entries = model.entries(in: folder.id)
                    if entries.isEmpty, model.unavailable(in: folder.id).isEmpty {
                        emptyNote("Empty folder")
                    }
                    UnavailableRows(model: model, folder: folder.id)
                    ForEach(entries) { entry in row(entry) }
                } label: {
                    Label(folder.name, systemImage: "folder")
                        .lineLimit(1)
                        .dropTargetHighlight(highlighted == folder.id)
                        .dropDestination(for: DraggedTranscripts.self) { items, _ in
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
                            .disabled(model.holdsTranscripts(folder.id))
                            Divider()
                            libraryMenu
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
                .disabled(model.foldersAreDamaged)
                .help("New folder")
                .accessibilityLabel("New folder")
                // Clear of the edge of the sidebar, where the scroller runs.
                .padding(.trailing, 6)
            }
            .contextMenu { libraryMenu }
        }
    }
}

// The sidebar's rows, drops and folder actions.
extension ContentView {
    private func emptyNote(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .contextMenu { libraryMenu }
    }

    private var libraryMenu: some View {
        LibraryMenu(model: model, newFolder: startNewFolder)
    }

    private func startNewFolder() {
        renamedFolder = nil
        folderName = ""
        namingFolder = true
    }

    private func row(_ entry: Entry) -> some View {
        let targets = targets(of: entry)
        let isWorking = entry.id == model.busyEntry || model.isWaitingForDownload(entry)
        return EntryRow(entry: entry, stage: isWorking ? model.stage : nil)
            .tag(AppModel.Pane.entry(entry.id))
            .draggable(DraggedTranscripts(ids: targets))
            .contextMenu {
                Button("Move to Folder…") {
                    destinationFolder = entry.folderID
                    moving = targets
                }
                .disabled(model.foldersAreDamaged)
                if targets.contains(where: { model.entry($0)?.folderID != nil }) {
                    Button("Remove from Folder") {
                        for id in targets { model.moveEntry(id, to: nil) }
                    }
                    .disabled(model.foldersAreDamaged)
                }
                // What belongs to one transcript is offered for one: undoing or
                // reverting several at once is not what a right click means.
                if targets.count == 1 {
                    Divider()
                    Button("Rename Transcript…") {
                        entryName = entry.name
                        renamedEntry = entry.id
                    }
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
                Divider()
                libraryMenu
            }
    }

    /// The transcripts an action on this row applies to: the whole selection
    /// when the row is part of it, so one menu acts on everything selected, and
    /// the row alone otherwise.
    private func targets(of entry: Entry) -> [Entry.ID] {
        guard selection.contains(.entry(entry.id)), selected.count > 1 else { return [entry.id] }
        return selected
    }

    /// The transcripts selected, in the order the list shows them.
    private var selected: [Entry.ID] {
        model.entries.map(\.id).filter { selection.contains(.entry($0)) }
    }

    /// A transcript dragged onto a folder, or onto the unfiled section to leave
    /// one.
    private func drop(_ items: [DraggedTranscripts], into folder: UUID?) -> Bool {
        guard model.moveEntries(items.flatMap(\.ids), to: folder) else { return false }
        if let folder { layout.openFolders.insert(folder) }
        return true
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { model.report(error) }
    }
}

#Preview {
    // An empty library and glossaries of its own, never the user's.
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    ContentView(
        model: AppModel(
            history: folder.appending(path: "History"),
            glossaries: folder.appending(path: "Glossaries")))
}
