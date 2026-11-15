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
    @State private var parentFolder: UUID?
    @State private var folderName = ""
    @State private var renamedEntry: Entry.ID?
    @State private var entryName = ""
    @State private var reverting: Entry?
    @State private var tagging: [Entry.ID] = []
    @State private var importingTranscript = false

    private var layout: WindowLayout { model.layout }

    init(model: AppModel) {
        self.model = model
        _selection = State(initialValue: model.pane == .new ? [] : [model.pane])
    }

    /// Room for the library, the page with its player and the inspector, so
    /// that nothing is cut; hiding the inspector narrows it.
    private var minimumWidth: CGFloat {
        guard layout.showsInspector, selected.count <= 1 else { return 860 }
        // At its widest: macOS squeezes a column below its minimum otherwise.
        let library = layout.showsLibrary ? Self.libraryWidths.upperBound : 0
        return max(860, library + PlayerBar.narrowest + 2 * Spacing.page + layout.inspectorWidth)
    }
    /// The library shown or hidden.
    private var columns: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { layout.showsLibrary ? .automatic : .detailOnly },
            set: { layout.showsLibrary = $0 != .detailOnly })
    }
    /// The library's widths: by default about as wide as the inspector, so
    /// the text sits between two balanced columns.
    static let libraryWidths: ClosedRange<CGFloat> = 220...340
    static let idealLibraryWidth: CGFloat = 300

    var body: some View {
        applyingSheets(to: applyingDialogs(to: splitContent))
            .minimumSize(width: minimumWidth, height: 600)
            .disabled(model.isShuttingDown)
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.isShuttingDown else { return false }
                model.transcribe(urls)
                return !urls.isEmpty
            }
    }

    private var splitContent: some View {
        NavigationSplitView(columnVisibility: columns) {
            LibrarySidebar(
                model: model,
                selection: $selection,
                selected: selected,
                removing: $removing,
                moving: $moving,
                destinationFolder: $destinationFolder,
                tagging: $tagging,
                renamedEntry: $renamedEntry,
                entryName: $entryName,
                reverting: $reverting,
                newFolder: { startNewFolder(in: $0) },
                renameFolder: { startRenameFolder($0) }
            )
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                if Self.libraryWidths.contains($0) { layout.libraryWidth = $0 }
            }
            .navigationSplitViewColumnWidth(
                min: Self.libraryWidths.lowerBound, ideal: layout.libraryWidth,
                max: Self.libraryWidths.upperBound
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
                        remove: { removing = $0 },
                        tag: { tagging = $0 }
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
            .minimumSize(width: PlayerBar.narrowest + 2 * Spacing.page, height: 450)
        }
        .focusedSceneValue(\.selectedTranscripts, activeTranscripts)
        .onChange(of: selection) { _, chosen in
            if chosen.contains(.new) {
                selection.remove(.new)
                return
            }
            // Several rows are a selection to act on, not a page to show, so
            // the window only follows a single one.
            guard chosen.count == 1, let only = chosen.first, only != model.pane else { return }
            model.pane = only
        }
        .onChange(of: model.pane) { _, pane in
            let expected: Set<AppModel.Pane> = pane == .new ? [] : [pane]
            guard selection != expected else { return }
            selection = expected
        }
        .onChange(of: model.visibleEntryOrder) { _, visibleOrder in
            guard selection.count > 1 else { return }
            let visiblePanes = Set(visibleOrder.map(AppModel.Pane.entry))
            let kept = selection.intersection(visiblePanes)
            if kept.isEmpty {
                if case .entry(let id) = model.pane, model.entry(id) != nil {
                    selection = [.entry(id)]
                } else {
                    selection.removeAll()
                }
            } else if kept != selection {
                selection = kept
            }
        }
        .task(id: model.newTranscriptionRequest) {
            guard model.newTranscriptionRequest != nil else { return }
            model.newTranscriptionRequest = nil
            selection.removeAll()
            model.pane = .new
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
        .alert(folderAlertTitle, isPresented: $namingFolder) {
            TextField("Folder name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button(renamedFolder == nil ? "Create" : "Rename") {
                attempt {
                    if let renamedFolder {
                        try model.renameFolder(renamedFolder, to: folderName)
                    } else {
                        let created = try model.createFolder(named: folderName, in: parentFolder)
                        model.revealFolder(created)
                    }
                }
            }
            .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Folders organize your library. Audio files stay where they are.")
        }
        .modifier(RenameAlert(renamed: $renamedEntry, name: $entryName, model: model))
    }

    private func applyingDialogs(to content: some View) -> some View {
        content
            .confirmationDialog(
                removing.count > 1
                    ? "Remove \(removing.count) transcripts from the library?"
                    : "Remove this transcript from the library?",
                isPresented: Binding(
                    get: { !removing.isEmpty }, set: { if !$0 { removing = [] } }
                )
            ) {
                Button(
                    removing.count > 1 ? "Remove Transcripts" : "Remove Transcript",
                    role: .destructive
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
    }

    private func applyingSheets(to content: some View) -> some View {
        content
            .sheet(
                isPresented: Binding(get: { !moving.isEmpty }, set: { if !$0 { moving = [] } })
            ) {
                MoveTranscriptsSheet(
                    model: model, moving: $moving, destinationFolder: $destinationFolder,
                    opened: {
                        if let folder = $0 {
                            model.revealFolder(folder)
                        } else {
                            layout.showsUnfiled = true
                        }
                    })
            }
            .sheet(
                isPresented: Binding(get: { !tagging.isEmpty }, set: { if !$0 { tagging = [] } })
            ) {
                NewTagSheet(model: model, targets: $tagging)
            }
    }

    private var folderAlertTitle: LocalizedStringKey {
        if renamedFolder != nil { return "Rename folder" }
        return parentFolder == nil ? "New folder" : "New subfolder"
    }
}

// Folder actions and selection helpers.
extension ContentView {
    private func startNewFolder(in parent: UUID? = nil) {
        renamedFolder = nil
        parentFolder = parent
        folderName = ""
        namingFolder = true
    }

    private func startRenameFolder(_ folder: TranscriptFolder) {
        renamedFolder = folder.id
        parentFolder = folder.parentID
        folderName = folder.name
        namingFolder = true
    }

    /// The visible transcripts selected, in the order the sidebar shows them.
    private var selected: [Entry.ID] {
        model.visibleEntryOrder.filter { selection.contains(.entry($0)) }
    }

    private var activeTranscripts: [Entry.ID] {
        if selected.count > 1 { return selected }
        guard case .entry(let id) = model.pane, model.entry(id) != nil else { return [] }
        return [id]
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
