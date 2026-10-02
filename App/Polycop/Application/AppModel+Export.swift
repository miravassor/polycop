// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

// MARK: Export

extension AppModel {
    /// What the export of a transcript is now, rather than what it was when it
    /// was written. The user may have moved, deleted or edited the file, or
    /// changed their mind about subtitles, since.
    enum Export: Equatable {
        /// Never exported.
        case none
        /// Exported, and nothing has changed since.
        case current
        /// The text, or the formats asked for, have changed since.
        case outOfDate
        /// What was written is no longer there.
        case missing
    }

    func exportState(of entry: Entry) -> Export {
        guard !entry.saved.isEmpty else { return .none }
        guard
            entry.saved.allSatisfy({
                FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
            })
        else { return .missing }
        // A subtitle or a layout changed since means other files, so there is
        // nothing to update: the export starts again from the save panel.
        guard entry.saved.map(\.pathExtension) == suffixes(of: entry) else { return .none }
        return entry.isSaved ? .current : .outOfDate
    }

    /// Writes the transcript where the user chose. The save panel is what
    /// asks before replacing a file, so what it returns is written as it is.
    func export(_ id: Entry.ID, to destination: URL) {
        write(id) { try Transcript.write($0, as: destination) }
    }

    /// Exports in the format chosen in the save panel, which becomes the
    /// transcript's export format from then on.
    func export(_ id: Entry.ID, as layout: Transcript.TextLayout, to destination: URL) {
        if entry(id)?.exportLayout != layout { setTextLayout(layout, for: id) }
        export(id, to: destination)
    }

    /// Writes over the files exported earlier. A file that something else has
    /// changed since is never replaced; the user is told, and can export it
    /// somewhere of their choosing instead.
    func updateExport(_ id: Entry.ID) {
        write(id) { formats in
            guard let entry = self.entry(id),
                let written = try Transcript.update(
                    entry.saved, holding: entry.savedDigests, with: formats)
            else { throw ExportError.changedElsewhere }
            return written
        }
    }

    enum ExportError: LocalizedError {
        case changedElsewhere

        var errorDescription: String? {
            String(
                localized:
                    "The exported file was changed outside Polycop and was left as it is. Export the transcript again to choose where to put it."
            )
        }
    }

    /// The files an export writes, without building their text.
    private func suffixes(of entry: Entry) -> [String] {
        [entry.exportLayout.suffix]
            + (entry.subtitles && entry.timesSentences ? ["srt"] : [])
    }

    private func formats(of entry: Entry) throws -> [(suffix: String, contents: Data)] {
        let layout = entry.exportLayout
        var paragraphs = entry.paragraphs
        if entry.removesHesitations == true {
            for index in paragraphs.indices {
                paragraphs[index].text = Hesitations.removed(from: paragraphs[index].text)
            }
            // A paragraph that was only "Euh." would export as a bare time.
            paragraphs.removeAll { $0.text.isEmpty }
        }
        let title = Transcript.suggestedName(
            for: entry.name, of: entry.recording, partial: entry.isPartial)
        let text =
            layout == .word
            ? try WordDocument.data(paragraphs, title: title)
            : Data(Transcript.text(paragraphs, layout: layout, title: title).utf8)
        var formats = [(suffix: layout.suffix, contents: text)]
        if entry.subtitles, entry.timesSentences {
            formats.append((suffix: "srt", contents: Data(Transcript.subRip(entry.shown).utf8)))
        }
        return formats
    }

    private func write(
        _ id: Entry.ID, _ writing: ([(suffix: String, contents: Data)]) throws -> [URL]
    ) {
        guard !isShuttingDown, let entry = entry(id), !entry.paragraphs.isEmpty else { return }
        failure = nil
        if entryFailure?.id == id { entryFailure = nil }
        let formats: [(suffix: String, contents: Data)]
        do {
            formats = try self.formats(of: entry)
        } catch {
            Log.persistence.error("an export could not be built: \(error, privacy: .private)")
            entryFailure = EntryFailure(id: id, message: error.localizedDescription)
            return
        }
        let digests = formats.map { Transcript.digest($0.contents) }
        do {
            let files = try writing(formats)
            updateEntry(id) {
                $0.saved = files
                $0.savedDigests = digests
                $0.isSaved = true
            }
        } catch let partial as Transcript.PartialSave {
            updateEntry(id) {
                $0.saved = partial.written
                $0.savedDigests = Array(digests.prefix(partial.written.count))
                $0.isSaved = false
            }
            entryFailure = EntryFailure(id: id, message: partial.localizedDescription)
        } catch {
            Log.persistence.error("an export could not be written: \(error, privacy: .private)")
            entryFailure = EntryFailure(id: id, message: error.localizedDescription)
        }
    }
}
