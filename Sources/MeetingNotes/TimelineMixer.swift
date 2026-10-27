import AVFoundation
import Foundation

/// Sums two independent live audio sources (microphone and system output) onto a
/// single 16 kHz mono timeline keyed on the mach host clock, then streams the
/// mixed result to disk.
///
/// Both sources arrive on their own threads at their own rates, so samples are
/// placed by timestamp rather than by arrival order. Anything older than
/// `lagToleranceSeconds` is considered final and flushed, which keeps memory flat
/// regardless of meeting length and degrades gracefully if one source stalls or
/// never starts (mic-only recording, for example).
final class TimelineMixer {
    enum Source: String, CaseIterable { case mic, system }

    static let sampleRate: Double = 16_000
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: TimelineMixer.sampleRate,
                                      channels: 1,
                                      interleaved: false)!

    private let queue = DispatchQueue(label: "app.meetingnotes.mixer")
    private let writer: WavWriter
    private let startHost: Double
    private let lagToleranceSeconds: Double = 2.0

    private var active: Set<Source> = []
    private var lastEndFrame: [Source: Int] = [:]
    private var window: [Float] = []
    private var windowStart: Int = 0
    private var finished = false

    var outputURL: URL { writer.url }

    init(url: URL) throws {
        writer = try WavWriter(url: url)
        startHost = TimelineMixer.hostSeconds()
    }

    static func hostSeconds() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    /// Marks a source as live. Only active sources hold back the flush boundary.
    func activate(_ source: Source) {
        queue.async { self.active.insert(source) }
    }

    func deactivate(_ source: Source) {
        queue.async {
            self.active.remove(source)
            self.lastEndFrame[source] = nil
        }
    }

    /// `samples` must already be 16 kHz mono float. `hostSeconds` is the capture
    /// time of the first sample.
    func add(samples: [Float], hostSeconds: Double, from source: Source) {
        guard !samples.isEmpty else { return }
        queue.async {
            guard !self.finished else { return }
            var startFrame = Int((hostSeconds - self.startHost) * TimelineMixer.sampleRate)
            var slice = samples[...]

            // Drop the portion that belongs to an already-flushed region.
            if startFrame < self.windowStart {
                let skip = self.windowStart - startFrame
                guard skip < slice.count else {
                    self.lastEndFrame[source] = max(self.lastEndFrame[source] ?? 0, startFrame + samples.count)
                    return
                }
                slice = slice.dropFirst(skip)
                startFrame = self.windowStart
            }

            let offset = startFrame - self.windowStart
            let needed = offset + slice.count
            if self.window.count < needed {
                self.window.append(contentsOf: repeatElement(0, count: needed - self.window.count))
            }
            var i = offset
            for s in slice {
                self.window[i] += s
                i += 1
            }
            self.lastEndFrame[source] = max(self.lastEndFrame[source] ?? 0, startFrame + slice.count)
            self.flush()
        }
    }

    /// Writes out every frame both sources have certainly finished with.
    private func flush(final: Bool = false) {
        guard !window.isEmpty || final else { return }
        var boundary: Int
        if final || active.isEmpty {
            boundary = windowStart + window.count
        } else {
            let nowFrame = Int((TimelineMixer.hostSeconds() - startHost) * TimelineMixer.sampleRate)
            let stallFloor = nowFrame - Int(lagToleranceSeconds * TimelineMixer.sampleRate)
            boundary = active.map { max(lastEndFrame[$0] ?? 0, stallFloor) }.min() ?? 0
            boundary = min(boundary, windowStart + window.count)
        }
        let count = boundary - windowStart
        guard count > 0 else { return }
        try? writer.append(window[0..<count])
        window.removeFirst(count)
        windowStart = boundary
    }

    /// Flushes the tail, closes the file and returns the finished recording.
    func finish() -> (url: URL, duration: TimeInterval) {
        queue.sync {
            guard !finished else { return }
            finished = true
            flush(final: true)
            writer.close()
        }
        return (writer.url, writer.duration)
    }

    var currentDuration: TimeInterval {
        max(0, TimelineMixer.hostSeconds() - startHost)
    }
}

/// Wraps a stateful `AVAudioConverter` so each source keeps its own resampler.
final class SourceConverter {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    /// Resamples and downmixes to 16 kHz mono, returning raw float samples.
    func convert(_ input: AVAudioPCMBuffer) -> [Float]? {
        guard input.frameLength > 0 else { return nil }
        if converter == nil || inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: TimelineMixer.format)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            inputFormat = input.format
        }
        guard let converter else { return nil }

        let ratio = TimelineMixer.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: TimelineMixer.format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}
