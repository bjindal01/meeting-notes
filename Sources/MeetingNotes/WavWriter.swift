import Foundation

/// Streaming 16-bit PCM WAV writer. Sizes in the header are patched on close,
/// so a crash mid-meeting still leaves a file most tools can recover.
final class WavWriter {
    let url: URL
    private let handle: FileHandle
    private let sampleRate: Int
    private let channels: Int
    private(set) var framesWritten: Int = 0
    private var closed = false

    init(url: URL, sampleRate: Int = 16_000, channels: Int = 1) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        fm.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: WavWriter.header(sampleRate: sampleRate, channels: channels, dataBytes: 0))
    }

    static func header(sampleRate: Int, channels: Int, dataBytes: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let byteRate = sampleRate * channels * 2
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(byteRate); u16(channels * 2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    /// Appends float samples in [-1, 1], clamping on the way to Int16.
    func append(_ samples: ArraySlice<Float>) throws {
        guard !samples.isEmpty, !closed else { return }
        var bytes = [UInt8]()
        bytes.reserveCapacity(samples.count * 2)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let v = Int16(clamped * 32767.0)
            bytes.append(UInt8(truncatingIfNeeded: v))
            bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        try handle.write(contentsOf: bytes)
        framesWritten += samples.count / channels
    }

    var duration: TimeInterval { Double(framesWritten) / Double(sampleRate) }

    func close() {
        guard !closed else { return }
        closed = true
        let dataBytes = framesWritten * channels * 2
        try? handle.synchronize()
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: WavWriter.header(sampleRate: sampleRate, channels: channels, dataBytes: dataBytes))
        try? handle.close()
    }
}

/// Reads back our own WAV files — used to split long recordings for the
/// hosted transcription APIs, which cap uploads at 25 MB.
enum WavReader {
    struct Info { let sampleRate: Int; let channels: Int; let bitsPerSample: Int; let dataOffset: Int; let dataBytes: Int }

    static func info(of url: URL) throws -> Info {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 4096), head.count > 44 else {
            throw AppError.audio("WAV file is too short to read")
        }
        func u32(_ o: Int) -> Int { Int(UInt32(head[o]) | UInt32(head[o+1]) << 8 | UInt32(head[o+2]) << 16 | UInt32(head[o+3]) << 24) }
        func u16(_ o: Int) -> Int { Int(UInt16(head[o]) | UInt16(head[o+1]) << 8) }
        var offset = 12
        var sampleRate = 16_000, channels = 1, bits = 16
        while offset + 8 <= head.count {
            let id = String(bytes: head[offset..<offset+4], encoding: .ascii) ?? ""
            let size = u32(offset + 4)
            if id == "fmt " {
                channels = u16(offset + 10); sampleRate = u32(offset + 12); bits = u16(offset + 22)
            } else if id == "data" {
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
                let available = (fileSize ?? (offset + 8 + size)) - (offset + 8)
                return Info(sampleRate: sampleRate, channels: channels, bitsPerSample: bits,
                            dataOffset: offset + 8, dataBytes: min(size, max(0, available)))
            }
            offset += 8 + size + (size % 2)
        }
        throw AppError.audio("No data chunk found in WAV file")
    }

    /// Splits into chunk files of at most `seconds` each. Returns the original
    /// URL alone when it already fits.
    static func split(_ url: URL, seconds: Int, into directory: URL) throws -> [URL] {
        let info = try info(of: url)
        let bytesPerFrame = info.channels * info.bitsPerSample / 8
        let chunkBytes = seconds * info.sampleRate * bytesPerFrame
        if info.dataBytes <= chunkBytes { return [url] }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(info.dataOffset))

        var parts: [URL] = []
        var index = 0
        var remaining = info.dataBytes
        while remaining > 0 {
            let take = min(chunkBytes, remaining)
            guard let data = try reader.read(upToCount: take), !data.isEmpty else { break }
            let part = directory.appendingPathComponent(String(format: "chunk-%03d.wav", index))
            var out = header(sampleRate: info.sampleRate, channels: info.channels, bits: info.bitsPerSample, dataBytes: data.count)
            out.append(data)
            try out.write(to: part)
            parts.append(part)
            remaining -= data.count
            index += 1
        }
        return parts
    }

    private static func header(sampleRate: Int, channels: Int, bits: Int, dataBytes: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(sampleRate * channels * bits / 8); u16(channels * bits / 8); u16(bits)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }
}
