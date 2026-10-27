import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

enum AppError: LocalizedError {
    case audio(String)
    case transcription(String)
    case summarization(String)
    case permission(String)

    var errorDescription: String? {
        switch self {
        case .audio(let m): return "Audio: \(m)"
        case .transcription(let m): return "Transcription: \(m)"
        case .summarization(let m): return "Summary: \(m)"
        case .permission(let m): return m
        }
    }
}

/// Captures the microphone (AVAudioEngine) and system output (ScreenCaptureKit)
/// simultaneously and mixes them into one 16 kHz mono WAV — the format
/// whisper.cpp wants, which avoids a conversion step later.
final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var mixer: TimelineMixer?
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private let micConverter = SourceConverter()
    private let systemConverter = SourceConverter()
    private let sckQueue = DispatchQueue(label: "app.meetingnotes.sck")

    private(set) var isRecording = false
    private(set) var capturedSystemAudio = false
    private(set) var startedAt: Date?

    var elapsed: TimeInterval { mixer?.currentDuration ?? 0 }

    // MARK: - Permissions

    static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func screenRecordingAuthorized() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt. Returns false the first time — macOS only
    /// grants the capability after the app is relaunched.
    @discardableResult
    static func requestScreenRecordingAccess() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: - Lifecycle

    func start(outputURL: URL, captureSystemAudio: Bool) async throws {
        guard !isRecording else { return }
        let mixer = try TimelineMixer(url: outputURL)
        self.mixer = mixer
        capturedSystemAudio = false

        var micError: Error?
        do { try startMicrophone(into: mixer) } catch { micError = error }

        if captureSystemAudio {
            do {
                try await startSystemAudio(into: mixer)
                capturedSystemAudio = true
            } catch {
                // A missing screen-recording grant should not lose the meeting;
                // fall back to mic-only and report it afterwards.
                NSLog("MeetingNotes: system audio unavailable — \(error.localizedDescription)")
                if micError != nil {
                    _ = mixer.finish()
                    self.mixer = nil
                    throw AppError.audio("neither microphone nor system audio could start")
                }
            }
        }

        if let micError, !capturedSystemAudio {
            _ = mixer.finish()
            self.mixer = nil
            throw micError
        }

        isRecording = true
        startedAt = Date()
    }

    private func startMicrophone(into mixer: TimelineMixer) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AppError.audio("no microphone input available")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self, let samples = self.micConverter.convert(buffer) else { return }
            let host = when.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: when.hostTime)
                : TimelineMixer.hostSeconds()
            mixer.add(samples: samples, hostSeconds: host, from: .mic)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        mixer.activate(.mic)
    }

    private func startSystemAudio(into mixer: TimelineMixer) async throws {
        guard AudioRecorder.screenRecordingAuthorized() else {
            throw AppError.permission("Screen Recording permission is not granted")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw AppError.audio("no display available to attach the audio capture to")
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // never record ourselves back
        config.sampleRate = 48_000
        config.channelCount = 2
        // ScreenCaptureKit requires a video configuration even for audio-only use;
        // keep it at the minimum so it costs nothing.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sckQueue)
        try await stream.startCapture()
        self.stream = stream
        mixer.activate(.system)
    }

    /// Stops both sources and finalises the WAV.
    func stop() async -> (url: URL, duration: TimeInterval)? {
        guard isRecording, let mixer else { return nil }
        isRecording = false

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        mixer.deactivate(.mic)

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        mixer.deactivate(.system)

        // Let the last in-flight buffers land before sealing the file.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let result = mixer.finish()
        self.mixer = nil
        self.startedAt = nil
        return result
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let mixer else { return }
        guard let pcm = AudioRecorder.pcmBuffer(from: sampleBuffer) else { return }
        guard let samples = systemConverter.convert(pcm) else { return }
        let host = sampleBuffer.presentationTimeStamp.seconds
        mixer.add(samples: samples, hostSeconds: host, from: .system)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("MeetingNotes: capture stream stopped — \(error.localizedDescription)")
        mixer?.deactivate(.system)
    }

    /// Copies a ScreenCaptureKit audio sample buffer into an `AVAudioPCMBuffer`.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription,
              var asbd = description.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames

        var copied = false
        try? sampleBuffer.withAudioBufferList { source, _ in
            let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            guard source.count == destination.count else { return }
            for i in 0..<destination.count {
                guard let src = source[i].mData, let dst = destination[i].mData else { return }
                let bytes = min(Int(source[i].mDataByteSize), Int(destination[i].mDataByteSize))
                memcpy(dst, src, bytes)
            }
            copied = true
        }
        return copied ? pcm : nil
    }
}
