import Foundation

/// Reads configuration from `.env` files and the process environment.
/// Nothing here ever leaves the machine except the API calls the user configures.
final class Config {
    static let shared = Config()

    private var values: [String: String] = [:]
    private let lock = NSLock()

    private init() { reload() }

    /// Files are read in order; later files win. The process environment wins over all of them.
    static var searchPaths: [URL] {
        var paths: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        paths.append(home.appendingPathComponent(".config/meetingnotes/.env"))
        paths.append(Config.defaultNotesDirectory.appendingPathComponent(".env"))
        // Alongside the .app bundle, which is handy while developing.
        let bundleDir = Bundle.main.bundleURL.deletingLastPathComponent()
        paths.append(bundleDir.appendingPathComponent(".env"))
        return paths
    }

    static var defaultNotesDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["NOTES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MeetingNotes")
    }

    func reload() {
        lock.lock()
        defer { lock.unlock() }
        var merged: [String: String] = [:]
        for url in Config.searchPaths {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (key, value) in Config.parse(text) { merged[key] = value }
        }
        for (key, value) in ProcessInfo.processInfo.environment where merged[key] == nil || !value.isEmpty {
            if Config.knownKeys.contains(key) { merged[key] = value }
        }
        values = merged
    }

    static let knownKeys: Set<String> = [
        "NOTES_DIR", "TRANSCRIBE_BACKEND", "WHISPER_BIN", "WHISPER_MODEL", "WHISPER_THREADS",
        "WHISPER_LANGUAGE", "OPENAI_API_KEY", "GROQ_API_KEY", "ANTHROPIC_API_KEY",
        "OPENAI_TRANSCRIBE_MODEL", "GROQ_TRANSCRIBE_MODEL", "LLM_PROVIDER", "LLM_MODEL",
        "OLLAMA_HOST", "OLLAMA_MODEL", "AUDIO_FORMAT", "CAPTURE_SYSTEM_AUDIO", "MEETING_TITLE_PREFIX",
    ]

    /// Minimal dotenv parser: `KEY=value`, `export KEY=value`, `#` comments, optional quotes.
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2)
                || (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
                value = String(value.dropFirst().dropLast())
            } else if let hash = value.range(of: " #") {
                value = String(value[value.startIndex..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    func string(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let v = values[key], !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return v.trimmingCharacters(in: .whitespaces)
    }

    func string(_ key: String, default fallback: String) -> String { string(key) ?? fallback }

    func bool(_ key: String, default fallback: Bool) -> Bool {
        guard let v = string(key)?.lowercased() else { return fallback }
        return ["1", "true", "yes", "on"].contains(v)
    }

    func int(_ key: String, default fallback: Int) -> Int {
        guard let v = string(key), let i = Int(v) else { return fallback }
        return i
    }

    var notesDirectory: URL {
        if let dir = string("NOTES_DIR") {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return Config.defaultNotesDirectory
    }

    var envFileURL: URL { notesDirectory.appendingPathComponent(".env") }

    // MARK: - whisper.cpp discovery

    /// Locates a whisper.cpp binary: explicit config first, then Homebrew / common build paths.
    var whisperBinary: URL? {
        if let p = string("WHISPER_BIN") {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp", "/usr/local/bin/whisper-cpp",
            "\(home)/whisper.cpp/build/bin/whisper-cli",
            "\(home)/whisper.cpp/build/bin/main",
            "\(home)/whisper.cpp/main",
        ]
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.components(separatedBy: ":") where !dir.isEmpty {
                candidates.append("\(dir)/whisper-cli")
                candidates.append("\(dir)/whisper-cpp")
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Locates a ggml model, preferring `medium` as requested.
    var whisperModel: URL? {
        let fm = FileManager.default
        if let p = string("WHISPER_MODEL") {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        let home = fm.homeDirectoryForCurrentUser
        let dirs = [
            notesDirectory.appendingPathComponent("models"),
            home.appendingPathComponent(".cache/whisper"),
            home.appendingPathComponent("whisper.cpp/models"),
            URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp/models"),
            URL(fileURLWithPath: "/usr/local/share/whisper-cpp/models"),
        ]
        // Preference order: medium first, then anything else usable.
        let preferred = ["ggml-medium.bin", "ggml-medium.en.bin", "ggml-medium-q5_0.bin"]
        for dir in dirs {
            for name in preferred {
                let url = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            if let any = files.filter({ $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }).sorted().first {
                return dir.appendingPathComponent(any)
            }
        }
        return nil
    }

    var canTranscribeLocally: Bool { whisperBinary != nil && whisperModel != nil }
}
