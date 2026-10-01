// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

nonisolated extension Entry {
    /// What a correction changes, kept to step it back: the text, and the
    /// course corrections a revert clears.
    struct Revision: Equatable, Sendable {
        let paragraphs: [Transcript.Paragraph]
        let courseCorrections: [CourseCorrection]?
    }

    var revision: Revision {
        Revision(paragraphs: paragraphs, courseCorrections: courseCorrections)
    }

    mutating func restore(_ revision: Revision) {
        paragraphs = revision.paragraphs
        courseCorrections = revision.courseCorrections
        isEdited = paragraphs != original
        isSaved = false
    }
}
