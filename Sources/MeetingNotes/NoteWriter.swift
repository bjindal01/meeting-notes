import Foundation

/// Writes the markdown note: summary at the top, full transcript below a divider.
enum NoteWriter {

    struct Note {
        let url: URL
        let audioURL: URL
    }

    static func basename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    static func humanTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM yyyy 'at' HH:mm"
        return formatter.string(from: date)
    }

    static func humanDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// Builds the note. `summary` and `transcript` are optional so a failed step
    /// still produces a file containing everything that did succeed.
    static func write(startedAt: Date,
                      duration: TimeInterval,
                      audioURL: URL,
                      transcript: String?,
                      transcriptEngine: String?,
                      summary: String?,
                      summaryEngine: String?,
                      warnings: [String],
                      in directory: URL) throws -> Note {
        var body = ""
        let titlePrefix = Config.shared.string("MEETING_TITLE_PREFIX", default: "Meeting Notes")
        body += "# \(titlePrefix) — \(humanTimestamp(startedAt))\n\n"
        body += "- **Duration:** \(humanDuration(duration))\n"
        body += "- **Audio:** [\(audioURL.lastPathComponent)](\(audioURL.lastPathComponent))\n"
        if let transcriptEngine { body += "- **Transcribed by:** \(transcriptEngine)\n" }
        if let summaryEngine { body += "- **Summarized by:** \(summaryEngine)\n" }
        body += "\n"

        if !warnings.isEmpty {
            body += "> [!NOTE]\n"
            for warning in warnings {
                body += "> \(warning)\n"
            }
            body += "\n"
        }

        if let summary, !summary.isEmpty {
            body += summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        } else {
            body += "## Summary\n\n_No summary was generated._\n\n## Decisions\n\n- _None recorded._\n\n## Action Items\n\n- _None recorded._\n"
        }

        body += "\n---\n\n## Transcript\n\n"
        if let transcript, !transcript.isEmpty {
            body += transcript.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        } else {
            body += "_No transcript is available. The audio file is still saved next to this note._\n"
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = uniqueURL(base: basename(for: startedAt), extension: "md", in: directory)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return Note(url: url, audioURL: audioURL)
    }

    /// Two meetings can start in the same minute; don't overwrite the first one.
    static func uniqueURL(base: String, extension ext: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }
}
