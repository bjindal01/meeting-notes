import Foundation

struct SummaryResult {
    let markdown: String
    let engine: String
}

enum LLMProvider: String {
    case auto, anthropic, openai, groq, ollama, none
}

/// Sends the transcript to an LLM and gets back the three sections that go at
/// the top of the note.
enum Summarizer {

    static let systemPrompt = """
    You are a meticulous meeting-notes assistant. You are given a raw transcript produced by \
    automatic speech recognition. It has no speaker labels, and it will contain misheard words, \
    filler words and false starts. Read past those errors and report what was actually discussed.

    Reply with GitHub-flavored Markdown containing exactly these three sections, in this order, \
    and nothing else — no preamble, no closing remarks, no code fences:

    ## Summary
    Exactly five bullets. Each is one sentence covering a distinct topic of substance, ordered \
    by importance rather than by when it came up.

    ## Decisions
    One bullet per decision the participants actually settled on. State the decision and, in the \
    same bullet, the reason if it was given.

    ## Action Items
    One bullet per commitment, formatted as:
    - [ ] **Owner** — what they agreed to do (due: when, if a date or timeframe was stated)
    Use the person's name as spoken. Write **Unassigned** when no owner was named.

    Rules:
    - Only state what the transcript supports. Never invent names, dates, numbers or commitments.
    - Where a name is clearly garbled by the transcription, use your best reading and do not flag it.
    - If a section genuinely has no content, write exactly: - _None recorded._
    - Do not add any section beyond the three above.
    """

    static func resolveProvider() -> LLMProvider {
        let configured = LLMProvider(rawValue: Config.shared.string("LLM_PROVIDER", default: "auto").lowercased()) ?? .auto
        guard configured == .auto else { return configured }
        if Config.shared.string("ANTHROPIC_API_KEY") != nil { return .anthropic }
        if Config.shared.string("OPENAI_API_KEY") != nil { return .openai }
        if Config.shared.string("GROQ_API_KEY") != nil { return .groq }
        if ollamaReachable() { return .ollama }
        return .none
    }

    static var ollamaHost: String { Config.shared.string("OLLAMA_HOST", default: "http://localhost:11434") }

    /// Asks a local Ollama what it has installed, so the app does not insist on a
    /// model name the user never pulled.
    static func ollamaModels() -> [String] {
        guard let url = URL(string: "\(ollamaHost)/api/tags") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        let semaphore = DispatchSemaphore(value: 0)
        var names: [String] = []
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return }
            names = models.compactMap { $0["name"] as? String }
        }.resume()
        _ = semaphore.wait(timeout: .now() + 2.5)
        return names
    }

    static func ollamaReachable() -> Bool {
        guard let url = URL(string: "\(ollamaHost)/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1.5)
        return reachable
    }

    static func model(for provider: LLMProvider) -> String {
        if let override = Config.shared.string("LLM_MODEL") { return override }
        switch provider {
        case .anthropic: return "claude-sonnet-5"
        case .openai: return "gpt-4o"
        case .groq: return "openai/gpt-oss-120b"
        case .ollama:
            if let configured = Config.shared.string("OLLAMA_MODEL") { return configured }
            let installed = ollamaModels()
            // Prefer a general-purpose instruct model, else whatever is there.
            let preferred = ["llama3.3", "llama3.2", "llama3.1", "qwen2.5", "mistral", "gemma"]
            for prefix in preferred {
                if let match = installed.first(where: { $0.hasPrefix(prefix) }) { return match }
            }
            return installed.first ?? "llama3.1:8b"
        case .auto, .none: return ""
        }
    }

    /// Roughly 4 characters per token; stay well inside a single request.
    private static let chunkCharacterLimit = 48_000

    static func summarize(transcript: String, progress: @escaping (String) -> Void) async throws -> SummaryResult {
        let provider = resolveProvider()
        guard provider != .none else {
            throw AppError.summarization("No LLM configured. Add ANTHROPIC_API_KEY, OPENAI_API_KEY or GROQ_API_KEY to \(Config.shared.envFileURL.path), or run Ollama locally.")
        }
        let modelName = model(for: provider)
        // Some model ids already carry a vendor prefix (openai/gpt-oss-120b);
        // don't end up with "groq/openai/...".
        let engine = modelName.contains("/") ? "\(provider.rawValue) \(modelName)" : "\(provider.rawValue)/\(modelName)"

        if transcript.count <= chunkCharacterLimit {
            progress("Summarizing with \(modelName)…")
            let text = try await complete(provider: provider, model: modelName,
                                          system: systemPrompt,
                                          user: "Transcript:\n\n\(transcript)")
            return SummaryResult(markdown: normalize(text), engine: engine)
        }

        // Long meeting: condense each slice, then summarize the condensations.
        let chunks = split(transcript, limit: chunkCharacterLimit)
        var digests: [String] = []
        for (index, chunk) in chunks.enumerated() {
            progress("Summarizing part \(index + 1) of \(chunks.count) with \(modelName)…")
            let digest = try await complete(
                provider: provider, model: modelName,
                system: "You condense part of a meeting transcript for a colleague who will write the final notes. Capture every topic, decision, commitment, owner name, number and date. Use terse bullets. Do not editorialize and do not add a preamble.",
                user: "This is part \(index + 1) of \(chunks.count) of the transcript:\n\n\(chunk)")
            digests.append("--- Part \(index + 1) ---\n\(digest)")
        }
        progress("Combining \(chunks.count) parts…")
        let combined = try await complete(
            provider: provider, model: modelName,
            system: systemPrompt,
            user: "The meeting was long, so here are ordered notes taken from consecutive parts of the transcript. Treat them as one meeting.\n\n\(digests.joined(separator: "\n\n"))")
        return SummaryResult(markdown: normalize(combined), engine: engine)
    }

    private static func split(_ text: String, limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            if current.count + paragraph.count > limit, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n\n") + paragraph
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Strips stray code fences some models wrap markdown in.
    private static func normalize(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("```") {
            var lines = out.components(separatedBy: .newlines)
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            out = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    // MARK: - Provider calls

    static func complete(provider: LLMProvider, model: String, system: String, user: String) async throws -> String {
        switch provider {
        case .anthropic: return try await callAnthropic(model: model, system: system, user: user)
        case .openai: return try await callOpenAICompatible(
            endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
            keyName: "OPENAI_API_KEY", label: "OpenAI", model: model, system: system, user: user)
        case .groq: return try await callOpenAICompatible(
            endpoint: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
            keyName: "GROQ_API_KEY", label: "Groq", model: model, system: system, user: user)
        case .ollama: return try await callOllama(model: model, system: system, user: user)
        case .auto, .none: throw AppError.summarization("no provider resolved")
        }
    }

    private static func callAnthropic(model: String, system: String, user: String) async throws -> String {
        guard let key = Config.shared.string("ANTHROPIC_API_KEY") else {
            throw AppError.summarization("ANTHROPIC_API_KEY is not set")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 4096,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ])

        let json = try await send(request, label: "Anthropic")
        guard let content = json["content"] as? [[String: Any]] else {
            throw AppError.summarization("unexpected Anthropic response shape")
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AppError.summarization("Anthropic returned an empty message") }
        return text
    }

    private static func callOpenAICompatible(endpoint: URL, keyName: String, label: String,
                                             model: String, system: String, user: String) async throws -> String {
        guard let key = Config.shared.string(keyName) else {
            throw AppError.summarization("\(keyName) is not set")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ])

        let json = try await send(request, label: label)
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty else {
            throw AppError.summarization("unexpected \(label) response shape")
        }
        return text
    }

    private static func callOllama(model: String, system: String, user: String) async throws -> String {
        guard let url = URL(string: "\(ollamaHost)/api/chat") else {
            throw AppError.summarization("invalid OLLAMA_HOST")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": false,
            "options": ["temperature": 0.2],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ])

        let json = try await send(request, label: "Ollama")
        guard let message = json["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty else {
            throw AppError.summarization("unexpected Ollama response shape")
        }
        return text
    }

    /// Best-effort lookup so a retired model name produces an actionable error.
    private static func availableModels(for label: String) -> [String] {
        let (endpoint, keyName): (String, String) = label == "Groq"
            ? ("https://api.groq.com/openai/v1/models", "GROQ_API_KEY")
            : ("https://api.openai.com/v1/models", "OPENAI_API_KEY")
        guard let url = URL(string: endpoint), let key = Config.shared.string(keyName) else { return [] }
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
                .filter { !$0.contains("whisper") && !$0.contains("tts") && !$0.contains("guard") }
                .sorted()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 12)
        return names
    }

    private static func send(_ request: URLRequest, label: String) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.summarization("no response from \(label)")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Providers retire model names regularly; a bare 404 is useless on its own.
            if http.statusCode == 404, body.contains("model") {
                throw AppError.summarization("\(label) does not have that model. Set LLM_MODEL in .env to one of: \(availableModels(for: label).joined(separator: ", "))")
            }
            throw AppError.summarization("\(label) returned HTTP \(http.statusCode): \(body.prefix(400))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.summarization("could not parse the \(label) response")
        }
        return json
    }
}
