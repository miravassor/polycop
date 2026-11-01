// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

// MARK: Export

extension AppModel {
    /// The file the last export wrote, while it is still there. An export is
    /// a copy to share or keep, made anew each time and never updated: the
    /// corrections live in the library.
    func lastExport(of entry: Entry) -> URL? {
        entry.saved.first.flatMap {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) ? $0 : nil
        }
    }

    /// Writes the transcript where the user chose. The save panel is what
    /// asks before replacing a file, so what it returns is written as it is.
    func export(_ id: Entry.ID, to destination: URL) {
        write(id) { try Transcript.write($0, as: destination) }
    }

    /// Makes this format the transcript's export, then writes it.
    func export(
        _ id: Entry.ID, as format: Transcript.Format, times: Bool, to destination: URL
    ) {
        if let entry = entry(id), entry.exportFormat != format || entry.exportsTimes != times {
            setExport(format, times: times, for: id)
        }
        export(id, to: destination)
    }

    private func formats(of entry: Entry) throws -> [(suffix: String, contents: Data)] {
        // The model's own words and timings, which corrections do not change.
        if entry.exportFormat == .subtitles {
            return [(suffix: "srt", contents: Data(Transcript.subRip(entry.shown).utf8))]
        }
        let layout = entry.exportLayout
        let times = entry.exportsTimes
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
            ? try WordDocument.data(paragraphs, title: title, times: times)
            : Data(Transcript.text(paragraphs, layout: layout, title: title, times: times).utf8)
        return [(suffix: layout.suffix, contents: text)]
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
        // Earlier versions update an export they find unchanged, by digest.
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
