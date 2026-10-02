// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The transcript as a Word document, laid out as the Markdown export is: the
/// title as a heading, then each paragraph after its time in bold. macOS
/// writes the file, the same way the transcript import reads one.
enum WordDocument {
    static func data(_ paragraphs: [Transcript.Paragraph], title: String) throws -> Data {
        // Fonts every word processor knows, rather than the system font,
        // which Word would replace with whatever it finds.
        let body = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
        let bold = NSFont(name: "Helvetica-Bold", size: 12) ?? .boldSystemFont(ofSize: 12)
        let heading = NSFont(name: "Helvetica-Bold", size: 18) ?? .boldSystemFont(ofSize: 18)
        let spaced = NSMutableParagraphStyle()
        spaced.paragraphSpacing = 10

        let document = NSMutableAttributedString(
            string: title + "\n", attributes: [.font: heading, .paragraphStyle: spaced])
        for paragraph in paragraphs {
            document.append(
                NSAttributedString(
                    string: paragraph.time + "  ",
                    attributes: [.font: bold, .paragraphStyle: spaced]))
            document.append(
                NSAttributedString(
                    string: paragraph.text + "\n",
                    attributes: [.font: body, .paragraphStyle: spaced]))
        }
        return try document.data(
            from: NSRange(location: 0, length: document.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }
}
