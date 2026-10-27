import AVFoundation
import Foundation

/// `MeetingNotes --selftest` exercises the offline half of the pipeline —
/// mixing, WAV writing, chunk splitting and note formatting — without needing a
/// microphone, a meeting or a network connection.
enum SelfTest {

    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            print(condition ? "  ok    \(name)" : "  FAIL  \(name) \(detail)")
            if !condition { failures += 1 }
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingnotes-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // --- Mixer: two sources on one timeline -----------------------------
        print("Mixer and WAV writer")
        let wavURL = scratch.appendingPathComponent("mix.wav")
        let seconds = 3.0
        do {
            let mixer = try TimelineMixer(url: wavURL)
            let base = TimelineMixer.hostSeconds()
            mixer.activate(.mic)
            mixer.activate(.system)
            let step = 0.1
            let framesPerStep = Int(TimelineMixer.sampleRate * step)
            var offset = 0.0
            while offset < seconds {
                // A 440 Hz tone on the mic and a 220 Hz tone on system audio,
                // each at half scale so the sum stays inside [-1, 1].
                let micChunk = tone(frequency: 440, startFrame: Int(offset * TimelineMixer.sampleRate), count: framesPerStep, amplitude: 0.5)
                let sysChunk = tone(frequency: 220, startFrame: Int(offset * TimelineMixer.sampleRate), count: framesPerStep, amplitude: 0.5)
                mixer.add(samples: micChunk, hostSeconds: base + offset, from: .mic)
                mixer.add(samples: sysChunk, hostSeconds: base + offset, from: .system)
                offset += step
            }
            let result = mixer.finish()
            check("wav file exists", FileManager.default.fileExists(atPath: result.url.path))
            check("duration is ~\(Int(seconds))s", abs(result.duration - seconds) < 0.2,
                  "got \(String(format: "%.3f", result.duration))s")

            let info = try WavReader.info(of: wavURL)
            check("header says 16 kHz mono 16-bit",
                  info.sampleRate == 16_000 && info.channels == 1 && info.bitsPerSample == 16)
            check("data chunk matches duration",
                  abs(Double(info.dataBytes) / 32_000.0 - seconds) < 0.2,
                  "got \(info.dataBytes) bytes")

            // Both tones must actually be present in the mix.
            let samples = try readSamples(wavURL)
            let peak = samples.map { abs($0) }.max() ?? 0
            check("mix is not silent", peak > 0.3, "peak \(String(format: "%.2f", peak))")
            check("mix does not clip", peak <= 1.0, "peak \(String(format: "%.2f", peak))")
            check("440 Hz (mic) present", energy(samples, at: 440) > 0.05)
            check("220 Hz (system) present", energy(samples, at: 220) > 0.05)
            check("330 Hz (neither) absent", energy(samples, at: 330) < 0.01)
        } catch {
            check("mixer ran", false, "\(error)")
        }

        // --- Late and out-of-order buffers ----------------------------------
        print("Out-of-order and single-source handling")
        do {
            let url = scratch.appendingPathComponent("late.wav")
            let mixer = try TimelineMixer(url: url)
            let base = TimelineMixer.hostSeconds()
            mixer.activate(.mic)
            // System audio never starts — mic-only recording must still finish.
            mixer.add(samples: tone(frequency: 440, startFrame: 16_000, count: 16_000, amplitude: 0.4), hostSeconds: base + 1.0, from: .mic)
            mixer.add(samples: tone(frequency: 440, startFrame: 0, count: 16_000, amplitude: 0.4), hostSeconds: base, from: .mic)
            let result = mixer.finish()
            check("mic-only recording completes", result.duration > 1.5, "got \(String(format: "%.2f", result.duration))s")
        } catch {
            check("mic-only recording completes", false, "\(error)")
        }

        // --- Chunk splitting for the hosted APIs ----------------------------
        print("WAV splitting (25 MB API limit)")
        do {
            let parts = try WavReader.split(wavURL, seconds: 1, into: scratch.appendingPathComponent("chunks"))
            check("3s splits into 3 one-second parts", parts.count == 3, "got \(parts.count)")
            let total = try parts.reduce(0.0) { sum, part in
                let info = try WavReader.info(of: part)
                return sum + Double(info.dataBytes) / 32_000.0
            }
            check("no audio lost in the split", abs(total - seconds) < 0.2, "got \(String(format: "%.2f", total))s")
            let unsplit = try WavReader.split(wavURL, seconds: 600, into: scratch)
            check("short files are not split", unsplit == [wavURL])
        } catch {
            check("splitting works", false, "\(error)")
        }

        // --- Config parsing --------------------------------------------------
        print("Config parsing")
        let parsed = Config.parse("""
        # comment
        export OPENAI_API_KEY=sk-test123
        LLM_MODEL="claude-sonnet-5"
        NOTES_DIR=~/Notes # trailing comment
        EMPTY=
        """)
        check("export prefix stripped", parsed["OPENAI_API_KEY"] == "sk-test123")
        check("quotes stripped", parsed["LLM_MODEL"] == "claude-sonnet-5")
        check("trailing comment stripped", parsed["NOTES_DIR"] == "~/Notes")
        check("empty value kept", parsed["EMPTY"] == "")

        // --- Note formatting -------------------------------------------------
        print("Note formatting")
        do {
            let started = Date()
            let note = try NoteWriter.write(
                startedAt: started, duration: 754,
                audioURL: scratch.appendingPathComponent("2026-01-01-0900.m4a"),
                transcript: "Alice said the migration is on track.",
                transcriptEngine: "whisper.cpp (ggml-medium.bin, local)",
                summary: "## Summary\n\n- Migration is on track.\n\n## Decisions\n\n- Ship Friday.\n\n## Action Items\n\n- [ ] **Alice** — finish the migration",
                summaryEngine: "anthropic/claude-sonnet-5",
                warnings: [], in: scratch)
            let text = try String(contentsOf: note.url, encoding: .utf8)
            check("filename is YYYY-MM-DD-HHMM.md",
                  note.url.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}-\d{4}\.md$"#, options: .regularExpression) != nil,
                  note.url.lastPathComponent)
            check("duration is humanized", text.contains("12m 34s"))
            check("summary sits above the divider",
                  text.range(of: "## Summary")!.lowerBound < text.range(of: "\n---\n")!.lowerBound)
            check("transcript sits below the divider",
                  text.range(of: "## Transcript")!.lowerBound > text.range(of: "\n---\n")!.lowerBound)
            check("audio is linked relatively", text.contains("](2026-01-01-0900.m4a)"))

            // A second meeting in the same minute must not overwrite the first.
            let again = try NoteWriter.write(startedAt: started, duration: 60,
                                             audioURL: scratch.appendingPathComponent("x.m4a"),
                                             transcript: nil, transcriptEngine: nil,
                                             summary: nil, summaryEngine: nil,
                                             warnings: ["Transcription failed: no model"], in: scratch)
            check("same-minute meetings do not collide", again.url != note.url)
            let fallback = try String(contentsOf: again.url, encoding: .utf8)
            check("failed run still writes a note", fallback.contains("## Transcript") && fallback.contains("no model"))
        } catch {
            check("note written", false, "\(error)")
        }

        // --- Transcript cleanup ----------------------------------------------
        print("Transcript cleanup")
        let cleaned = Transcriber.cleanup("  [BLANK_AUDIO]\n Hello there. \n\n [MUSIC] \n Second line.  ")
        check("markers and blank lines removed", cleaned == "Hello there. Second line.", "got \(cleaned.debugDescription)")

        print("")
        if failures == 0 {
            print("All self-tests passed.")
        } else {
            print("\(failures) self-test(s) failed.")
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: - Helpers

    private static func tone(frequency: Double, startFrame: Int, count: Int, amplitude: Float) -> [Float] {
        (0..<count).map { i in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(startFrame + i) / TimelineMixer.sampleRate))
        }
    }

    private static func readSamples(_ url: URL) throws -> [Float] {
        let info = try WavReader.info(of: url)
        let data = try Data(contentsOf: url)
        var out: [Float] = []
        out.reserveCapacity(info.dataBytes / 2)
        var i = info.dataOffset
        while i + 1 < info.dataOffset + info.dataBytes && i + 1 < data.count {
            let value = Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8)
            out.append(Float(value) / 32767.0)
            i += 2
        }
        return out
    }

    /// Single-bin Goertzel-style correlation: how much of `frequency` is in the signal.
    private static func energy(_ samples: [Float], at frequency: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        var real = 0.0, imaginary = 0.0
        for (i, s) in samples.enumerated() {
            let angle = 2 * Double.pi * frequency * Double(i) / TimelineMixer.sampleRate
            real += Double(s) * cos(angle)
            imaginary += Double(s) * sin(angle)
        }
        return sqrt(real * real + imaginary * imaginary) / Double(samples.count)
    }
}

/// `MeetingNotes --test-summary` runs a short sample transcript through whatever
/// LLM the .env resolves to, so configuration problems surface before a meeting
/// rather than after one.
enum SummaryCheck {
    static let sample = """
    Right, let's start. Priya, where are we on the billing migration?

    We're about eighty percent through. The double-write is live in staging and we \
    haven't seen drift for four days. The blocker is the legacy invoice PDFs, there's \
    about forty thousand of them and the renderer chokes above ten megabytes.

    How long to fix the renderer?

    Two days if I can drop the old template support. Nobody has used it since March.

    Okay, drop it. Priya, you own that, let's say end of Thursday. Marcus, what about the \
    load test?

    I ran it Friday. We hit four thousand requests a second before latency went past two \
    hundred milliseconds. That's twice our peak, so I think we're fine.

    Good. Then I think we cut over on the fourteenth rather than waiting for the end of \
    the month. Any objections? No? Decided, the fourteenth.

    One thing, we should tell support before we cut over, not after, like last time.

    Fair. Marcus, can you write the support briefing by Wednesday?

    Yep, I'll do it.

    Last item, the on-call rotation. We're still short for the holiday weeks. I'll take \
    one of them but we need a second volunteer. Let's park it and pick it up next week.
    """

    static func run() async -> Int32 {
        Config.shared.reload()
        let provider = Summarizer.resolveProvider()
        guard provider != .none else {
            print("No LLM is configured.")
            print("Add ANTHROPIC_API_KEY, OPENAI_API_KEY or GROQ_API_KEY to \(Config.shared.envFileURL.path),")
            print("or run Ollama locally for a fully offline summary.")
            return 1
        }
        let modelName = Summarizer.model(for: provider)
        print("Provider: \(provider.rawValue)")
        print("Model:    \(modelName)")
        print("")
        let started = Date()
        do {
            let result = try await Summarizer.summarize(transcript: sample) { print("… \($0)") }
            print("")
            print(result.markdown)
            print("")
            print("Took \(String(format: "%.1f", Date().timeIntervalSince(started)))s.")

            // The note template depends on these three headings existing.
            let missing = ["## Summary", "## Decisions", "## Action Items"].filter { !result.markdown.contains($0) }
            if missing.isEmpty {
                print("All three sections present.")
                return 0
            }
            print("Warning: the model omitted \(missing.joined(separator: ", ")).")
            return 1
        } catch {
            print("Failed: \(error.localizedDescription)")
            return 1
        }
    }
}
