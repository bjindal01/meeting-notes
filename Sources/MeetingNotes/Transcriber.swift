import Foundation

struct TranscriptionResult {
    let text: String
    /// Human-readable description of what actually did the work, recorded in the note.
    let engine: String
}

enum TranscribeBackend: String {
    case auto, local, openai, groq, mistral
}

/// Turns the recorded WAV into text, preferring the fully offline path.
enum Transcriber {

    static func resolveBackend() -> TranscribeBackend {
        let configured = TranscribeBackend(rawValue: Config.shared.string("TRANSCRIBE_BACKEND", default: "auto").lowercased()) ?? .auto
        guard configured == .auto else { return configured }
        if Config.shared.canTranscribeLocally { return .local }
        if Config.shared.string("GROQ_API_KEY") != nil { return .groq }
        if Config.shared.string("MISTRAL_API_KEY") != nil { return .mistral }
        if Config.shared.string("OPENAI_API_KEY") != nil { return .openai }
        return .local   // will fail with a useful message about installing whisper.cpp
    }

    static func transcribe(url: URL, progress: @escaping (String) -> Void) async throws -> TranscriptionResult {
        let configured = Config.shared.string("TRANSCRIBE_BACKEND", default: "auto").lowercased()
        guard TranscribeBackend(rawValue: configured) != nil else {
            throw AppError.transcription("TRANSCRIBE_BACKEND=\"\(configured)\" is not recognized. Use auto, local, openai, groq or mistral. If you just added a backend to the source, install the new build.")
        }
        switch resolveBackend() {
        case .local, .auto:
            return try await local(url: url, progress: progress)
        case .openai:
            return try await api(url: url, provider: .openai, progress: progress)
        case .groq:
            return try await api(url: url, provider: .groq, progress: progress)
        case .mistral:
            return try await api(url: url, provider: .mistral, progress: progress)
        }
    }

    // MARK: - whisper.cpp

    static func local(url: URL, progress: @escaping (String) -> Void) async throws -> TranscriptionResult {
        let config = Config.shared
        guard let binary = config.whisperBinary else {
            throw AppError.transcription("whisper.cpp not found. Install it with `brew install whisper-cpp`, or set WHISPER_BIN in .env. See the README.")
        }
        guard let model = config.whisperModel else {
            throw AppError.transcription("No ggml model found. Run `./install-deps.sh` to download ggml-medium.bin, or set WHISPER_MODEL in .env.")
        }

        progress("Transcribing locally (\(model.lastPathComponent))…")
        var args = [
            "-m", model.path,
            "-f", url.path,
            "-nt",                                              // no timestamps in the output
            "-np",                                              // no progress chatter
            "-t", String(config.int("WHISPER_THREADS", default: max(4, ProcessInfo.processInfo.activeProcessorCount - 2))),
        ]
        let language = config.string("WHISPER_LANGUAGE", default: "auto")
        args.append(contentsOf: ["-l", language])

        let (status, stdout, stderr) = try run(binary, args, timeout: 60 * 60 * 6)
        guard status == 0 else {
            let detail = stderr.isEmpty ? stdout : stderr
            throw AppError.transcription("whisper.cpp exited with code \(status).\n\(detail.suffix(600))")
        }
        let text = cleanup(stdout)
        guard !text.isEmpty else {
            throw AppError.transcription("whisper.cpp produced no text — the recording may be silent.")
        }
        return TranscriptionResult(text: text, engine: "whisper.cpp (\(model.lastPathComponent), local)")
    }

    // MARK: - Hosted Whisper

    enum APIProvider {
        case openai, groq, mistral

        var endpoint: URL {
            switch self {
            case .openai: return URL(string: "https://api.openai.com/v1/audio/transcriptions")!
            case .groq: return URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
            case .mistral: return URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!
            }
        }

        var keyName: String {
            switch self {
            case .openai: return "OPENAI_API_KEY"
            case .groq: return "GROQ_API_KEY"
            case .mistral: return "MISTRAL_API_KEY"
            }
        }

        var label: String {
            switch self {
            case .openai: return "OpenAI"
            case .groq: return "Groq"
            case .mistral: return "Mistral"
            }
        }

        var model: String {
            switch self {
            case .openai: return Config.shared.string("OPENAI_TRANSCRIBE_MODEL", default: "whisper-1")
            case .groq: return Config.shared.string("GROQ_TRANSCRIBE_MODEL", default: "whisper-large-v3")
            // voxtral-small-transcribe-3 is the larger, more accurate sibling.
            case .mistral: return Config.shared.string("MISTRAL_TRANSCRIBE_MODEL", default: "voxtral-mini-transcribe-3")
            }
        }

        /// OpenAI and Groq cap uploads at 25 MB, which 10 minutes of 16 kHz mono
        /// stays under. Mistral documents no size cap; its real limit is a 65,536
        /// token context, and audio costs roughly 22 tokens per second — about 49
        /// minutes. 25 minutes leaves generous headroom.
        var chunkSeconds: Int { self == .mistral ? 1500 : 600 }

        /// Mistral returns JSON; the others accept response_format=text and return
        /// the transcript as the raw body.
        var returnsJSON: Bool { self == .mistral }

        var modelKeyName: String {
            switch self {
            case .openai: return "OPENAI_TRANSCRIBE_MODEL"
            case .groq: return "GROQ_TRANSCRIBE_MODEL"
            case .mistral: return "MISTRAL_TRANSCRIBE_MODEL"
            }
        }

        var modelsEndpoint: URL? {
            switch self {
            case .openai: return URL(string: "https://api.openai.com/v1/models")
            case .groq: return URL(string: "https://api.groq.com/openai/v1/models")
            case .mistral: return URL(string: "https://api.mistral.ai/v1/models")
            }
        }
    }

    static func api(url: URL, provider: APIProvider, progress: @escaping (String) -> Void) async throws -> TranscriptionResult {
        guard let key = Config.shared.string(provider.keyName) else {
            throw AppError.transcription("\(provider.keyName) is not set in \(Config.shared.envFileURL.path)")
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingnotes-chunks-\(UUID().uuidString)")
        let chunks = try WavReader.split(url, seconds: provider.chunkSeconds, into: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var pieces: [String] = []
        for (index, chunk) in chunks.enumerated() {
            if chunks.count > 1 {
                progress("Transcribing via \(provider.label) (part \(index + 1) of \(chunks.count))…")
            } else {
                progress("Transcribing via \(provider.label)…")
            }
            pieces.append(try await uploadChunk(chunk, provider: provider, key: key))
        }

        let text = cleanup(pieces.joined(separator: " "))
        guard !text.isEmpty else {
            throw AppError.transcription("\(provider.label) returned no text — the recording may be silent.")
        }
        return TranscriptionResult(text: text, engine: "\(provider.label) \(provider.model)")
    }

    private static func uploadChunk(_ fileURL: URL, provider: APIProvider, key: String) async throws -> String {
        let boundary = "----MeetingNotes\(UUID().uuidString)"
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("model", provider.model)
        // Mistral's endpoint does not document response_format and answers in JSON.
        if !provider.returnsJSON { field("response_format", "text") }
        if let language = Config.shared.string("WHISPER_LANGUAGE"), language != "auto" {
            field("language", language)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.transcription("no response from \(provider.label)")
        }
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            // A wrong model name is the most likely cause, and providers rename
            // them, so say which ones this account can actually use.
            if [400, 404, 422].contains(http.statusCode), responseBody.contains("model") {
                let available = transcriptionModels(for: provider)
                if !available.isEmpty {
                    throw AppError.transcription("\(provider.label) rejected model \"\(provider.model)\". Set \(provider.modelKeyName) in .env to one of: \(available.joined(separator: ", "))")
                }
            }
            throw AppError.transcription("\(provider.label) returned HTTP \(http.statusCode): \(responseBody.prefix(400))")
        }
        guard provider.returnsJSON else { return responseBody }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw AppError.transcription("could not read the transcript from the \(provider.label) response: \(responseBody.prefix(300))")
        }
        return text
    }

    /// Best-effort model listing, so a renamed model produces an actionable error.
    private static func transcriptionModels(for provider: APIProvider) -> [String] {
        guard let url = provider.modelsEndpoint, let key = Config.shared.string(provider.keyName) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let semaphore = DispatchSemaphore(value: 0)
        var names: [String] = []
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else { return }
            names = models.compactMap { $0["id"] as? String }
                .filter { $0.contains("transcribe") || $0.contains("whisper") || $0.contains("voxtral") }
                .sorted()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 12)
        return names
    }

    // MARK: - Helpers

    /// Runs a subprocess, draining both pipes concurrently so a chatty binary
    /// cannot deadlock on a full pipe buffer.
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let ioQueue = DispatchQueue(label: "app.meetingnotes.proc-io", attributes: .concurrent)
        group.enter()
        ioQueue.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        ioQueue.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            throw AppError.transcription("timed out after \(Int(timeout / 60)) minutes")
        }
        group.wait()
        return (process.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }

    /// whisper emits bracketed non-speech markers and ragged whitespace; tidy both.
    static func cleanup(_ raw: String) -> String {
        var lines: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            for marker in ["[BLANK_AUDIO]", "[SILENCE]", "(silence)", "[MUSIC]", "[ Silence ]"] {
                trimmed = trimmed.replacingOccurrences(of: marker, with: "")
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        // Re-wrap into paragraphs at sentence ends so the transcript stays readable.
        var paragraphs: [String] = []
        var current = ""
        for line in lines {
            current += (current.isEmpty ? "" : " ") + line
            if current.count > 400, let last = current.last, ".?!".contains(last) {
                paragraphs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
