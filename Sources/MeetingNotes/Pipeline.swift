import Foundation

/// Everything that happens after the user hits Stop.
///
/// Each stage is allowed to fail without losing the ones before it: a failed
/// summary still produces a note with the full transcript, and a failed
/// transcription still produces a note pointing at the saved audio.
enum Pipeline {

    struct Output {
        let noteURL: URL
        let audioURL: URL
        let warnings: [String]
    }

    static func process(wavURL: URL,
                        startedAt: Date,
                        duration: TimeInterval,
                        capturedSystemAudio: Bool,
                        progress: @escaping (String) -> Void) async -> Result<Output, Error> {
        let directory = Config.shared.notesDirectory
        var warnings: [String] = []
        if !capturedSystemAudio {
            warnings.append("System audio was not captured — this recording is microphone only. Grant Screen Recording permission and restart the app to include the other side of the call.")
        }

        var transcript: String?
        var transcriptEngine: String?
        do {
            let result = try await Transcriber.transcribe(url: wavURL, progress: progress)
            transcript = result.text
            transcriptEngine = result.engine
        } catch {
            warnings.append("Transcription failed: \(error.localizedDescription)")
        }

        var summary: String?
        var summaryEngine: String?
        if let transcript, !transcript.isEmpty {
            do {
                let result = try await Summarizer.summarize(transcript: transcript, progress: progress)
                summary = result.markdown
                summaryEngine = result.engine
            } catch {
                warnings.append("Summary failed: \(error.localizedDescription)")
            }
        }

        // Keep the audio next to the note, optionally compressed once we no
        // longer need the 16 kHz WAV for transcription.
        progress("Saving…")
        let audioURL = finalizeAudio(wavURL: wavURL, startedAt: startedAt, in: directory, warnings: &warnings)

        do {
            let note = try NoteWriter.write(startedAt: startedAt,
                                            duration: duration,
                                            audioURL: audioURL,
                                            transcript: transcript,
                                            transcriptEngine: transcriptEngine,
                                            summary: summary,
                                            summaryEngine: summaryEngine,
                                            warnings: warnings,
                                            in: directory)
            return .success(Output(noteURL: note.url, audioURL: audioURL, warnings: warnings))
        } catch {
            return .failure(error)
        }
    }

    /// Moves the recording into the notes folder, converting to m4a when asked
    /// (a one-hour meeting drops from ~115 MB to ~7 MB).
    private static func finalizeAudio(wavURL: URL, startedAt: Date, in directory: URL, warnings: inout [String]) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = NoteWriter.basename(for: startedAt)
        let wantsM4A = Config.shared.string("AUDIO_FORMAT", default: "m4a").lowercased() == "m4a"

        if wantsM4A, fm.isExecutableFile(atPath: "/usr/bin/afconvert") {
            let target = NoteWriter.uniqueURL(base: base, extension: "m4a", in: directory)
            do {
                let (status, _, stderr) = try Transcriber.run(
                    URL(fileURLWithPath: "/usr/bin/afconvert"),
                    ["-f", "m4af", "-d", "aac", "-b", "32000", wavURL.path, target.path],
                    timeout: 900)
                if status == 0, fm.fileExists(atPath: target.path) {
                    try? fm.removeItem(at: wavURL)
                    return target
                }
                warnings.append("Could not compress the audio to m4a (afconvert: \(stderr.prefix(160))); kept the WAV instead.")
            } catch {
                warnings.append("Could not compress the audio to m4a: \(error.localizedDescription); kept the WAV instead.")
            }
        }

        let target = NoteWriter.uniqueURL(base: base, extension: "wav", in: directory)
        if wavURL == target { return target }
        do {
            try fm.moveItem(at: wavURL, to: target)
            return target
        } catch {
            return wavURL
        }
    }
}
