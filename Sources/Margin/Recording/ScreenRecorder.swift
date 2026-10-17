import AVFoundation
import CoreMedia
import MarginKit
import ScreenCaptureKit
import VideoToolbox

/// What one recording captures and how (spec §14.4), worked out on the main actor (`RecordingController.source`).
struct RecordingSource: @unchecked Sendable {
    /// A display's (Margin's capture UI excluded, as in screenshots) or a window's on its own.
    let filter: SCContentFilter
    /// An area, in the display's points from its top-left corner; nil for the whole display or a window.
    let sourceRect: CGRect?
    /// What's recorded, in pixels at the display's native scale.
    let pixels: CGSize
    let fps: Int
    /// A window: a window that grows is scaled down into the frame instead of cut off.
    let isWindow: Bool
    let systemAudio: Bool
    let microphone: Bool

    /// The encoded size (`RecordingFormat.videoSize`): `pixels`, even, inside H.264's limits.
    var videoSize: CGSize { RecordingFormat.videoSize(forPixels: pixels, fps: fps) }
}

/// An `SCStream` straight into an `AVAssetWriter`: hardware H.264 in an MPEG-4 file, with AAC for the audio. Every
/// sample is handled on one serial queue, appended as ScreenCaptureKit delivers it (420v, so the encoder takes the
/// frame's own surface: no copy, no colour conversion), or dropped when the encoder isn't ready for it rather than
/// queued. Nothing of this exists until a recording starts.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// How a recording ended, from the recorder's side.
    struct Outcome: Sendable {
        /// The finished file (still the temp file), or nil when nothing usable was written.
        let url: URL?
        /// From the first frame to the stop.
        let duration: TimeInterval
        let framesWritten: Int
        let framesDropped: Int
        let error: String?
    }

    /// Live numbers for the DEBUG state dump.
    struct Stats: Sendable {
        var framesWritten = 0
        var framesDropped = 0
        var audioSamples = 0
        var microphoneSamples = 0
    }

    /// What the recorder tells its owner, on its own queue. Given at the start, before the first frame can arrive.
    struct Callbacks: Sendable {
        /// The first frame was written: the recording's clock starts.
        var firstFrame: @Sendable () -> Void = {}
        /// ScreenCaptureKit stopped the stream itself (the window closed, the display went, the user stopped it from the
        /// menu bar, an error), or the writer failed.
        var interrupted: @Sendable (any Error) -> Void = { _ in }
    }

    let url: URL
    let source: RecordingSource
    private let callbacks: Callbacks

    private let queue = DispatchQueue(label: "io.github.jenish-shobhit.margin.recorder", qos: .userInitiated)
    private let stream: SCStream
    /// The stream's delegate, which it holds weakly.
    private let forwarder: DelegateForwarder
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let mic: AVAssetWriterInput?

    // Confined to `queue`.
    private var firstTime: CMTime?
    private var lastTime = CMTime.invalid
    /// The newest frame, kept for the end: a screen that stopped changing sends no more frames, so it's appended again
    /// at the stop, and the file lasts as long as the recording did.
    private var lastFrame: CMSampleBuffer?
    private var stats = Stats()
    private var finished = false
    private var interrupted = false

    /// ScreenCaptureKit sends a frame only when something changed, and holds each one (an IOSurface from its pool)
    /// until the encoder has it: enough for the encoder to be a frame or two behind, plus the one kept for the end.
    private static let queueDepth = 6
    /// AAC at 48 kHz.
    private static let audioRate = 48_000

    private init(url: URL, source: RecordingSource, writer: AVAssetWriter, video: AVAssetWriterInput,
                 audio: AVAssetWriterInput?, mic: AVAssetWriterInput?, configuration: SCStreamConfiguration,
                 callbacks: Callbacks) {
        self.url = url
        self.source = source
        self.callbacks = callbacks
        self.writer = writer
        self.video = video
        self.audio = audio
        self.mic = mic
        // The delegate goes in with the stream, before `self` exists: a forwarder that's pointed at it afterwards.
        let forwarder = DelegateForwarder()
        self.forwarder = forwarder
        stream = SCStream(filter: source.filter, configuration: configuration, delegate: forwarder)
        super.init()
        forwarder.recorder = self
    }

    /// Builds the writer for a new file at `url` (which must not exist) and starts capturing. Throws `RecorderError.file`
    /// if the file can't be created (the folder isn't writable: the caller tries the Unsaved folder), or ScreenCaptureKit's
    /// error if it won't start; nothing is left behind either way.
    static func start(_ source: RecordingSource, to url: URL, callbacks: Callbacks) async throws -> ScreenRecorder {
        let size = source.videoSize
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw RecorderError.file(error.localizedDescription)
        }
        // The index stays at the end (no `shouldOptimizeForNetworkUse`): moving it to the front rewrites the whole movie
        // when it's finished, which takes as much free space again and seconds for a long one, and a file played or
        // uploaded from disk doesn't need it first.
        writer.shouldOptimizeForNetworkUse = false
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(size: size, fps: source.fps))
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecorderError.failed("The video track couldn’t be set up") }
        writer.add(video)
        let audio = source.systemAudio ? audioInput(channels: 2) : nil
        let mic = source.microphone ? audioInput(channels: 1) : nil
        for input in [audio, mic].compactMap({ $0 }) where writer.canAdd(input) { writer.add(input) }

        let config = configuration(for: source, size: size)
        let recorder = ScreenRecorder(url: url, source: source, writer: writer, video: video,
                                      audio: audio.flatMap { writer.inputs.contains($0) ? $0 : nil },
                                      mic: mic.flatMap { writer.inputs.contains($0) ? $0 : nil }, configuration: config,
                                      callbacks: callbacks)
        try recorder.addOutputs()
        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.file(writer.error?.localizedDescription ?? "The file couldn’t be created")
        }
        do {
            try await recorder.stream.startCapture()
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return recorder
    }

    /// Every kind of sample on the one queue, so the writer is only ever touched there.
    private func addOutputs() throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audio != nil { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if mic != nil { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
    }

    // MARK: Settings

    /// Hardware H.264 (High profile), at `RecordingFormat.bitRate`, a key frame every 2 s, no B-frames (real time), tagged
    /// BT.709 like the sRGB frames ScreenCaptureKit is asked for.
    static func videoSettings(size: CGSize, fps: Int) -> [String: Any] {
        let width = Int(size.width), height = Int(size.height)
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: RecordingFormat.bitRate(width: width, height: height, fps: fps),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]
    }

    private static func audioInput(channels: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    static func configuration(for source: RecordingSource, size: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        // A shade under a frame (0.9 of one): refreshes come a little early or late, and an interval of exactly 1/fps
        // skips the early ones (about one in fourteen at 60 Hz, each shown twice as long). Still never two refreshes
        // of a 120 Hz display in a 60 fps recording.
        config.minimumFrameInterval = CMTime(value: 9, timescale: CMTimeScale(source.fps * 10))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.showsCursor = true
        config.captureResolution = .best
        config.queueDepth = queueDepth
        if let rect = source.sourceRect { config.sourceRect = rect }
        if source.isWindow {
            // A window has transparent corners and can be resized: opaque, and scaled down into the frame if it grows.
            config.ignoreShadowsSingleWindow = true
            config.ignoreGlobalClipSingleWindow = true
            config.shouldBeOpaque = true
            config.scalesToFit = true
            config.preservesAspectRatio = true
        } else {
            config.scalesToFit = false
        }
        if source.systemAudio {
            config.capturesAudio = true
            // The start tick, the shutter of a screenshot taken meanwhile: Margin's own sounds stay out.
            config.excludesCurrentProcessAudio = true
            config.sampleRate = audioRate
            config.channelCount = 2
        }
        if source.microphone { config.captureMicrophone = true }
        return config
    }

    // MARK: Samples

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, sampleBuffer.isValid else { return }
        switch type {
        case .screen: appendFrame(sampleBuffer)
        case .audio: appendAudio(sampleBuffer, to: audio) { $0.audioSamples += 1 }
        case .microphone: appendAudio(sampleBuffer, to: mic) { $0.microphoneSamples += 1 }
        @unknown default: break
        }
    }

    private func appendFrame(_ sample: CMSampleBuffer) {
        // Only frames with new content: an idle frame has no image.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              CMSampleBufferGetImageBuffer(sample) != nil else { return }
        let time = sample.presentationTimeStamp
        if firstTime == nil {
            writer.startSession(atSourceTime: time)
            firstTime = time
            callbacks.firstFrame()
        }
        guard video.isReadyForMoreMediaData else {
            // A writer that failed (the encoder or the disk gave up) is never ready again: that stops the recording,
            // rather than it going on, counting every frame as dropped, until the user stops it and nothing is saved.
            if writer.status == .failed { writerFailed() } else { stats.framesDropped += 1 }
            return
        }
        guard video.append(sample) else {
            writerFailed()
            return
        }
        stats.framesWritten += 1
        lastTime = time
        lastFrame = sample
    }

    private func appendAudio(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?, count: (inout Stats) -> Void) {
        // Audio before the first frame has nothing to go with.
        guard let input, let first = firstTime, sample.presentationTimeStamp >= first else { return }
        guard input.isReadyForMoreMediaData else {
            if writer.status == .failed { writerFailed() }
            return
        }
        if input.append(sample) { count(&stats) } else { writerFailed() }
    }

    private func writerFailed() {
        guard !interrupted else { return }
        interrupted = true
        callbacks.interrupted(writer.error ?? RecorderError.failed("The encoder stopped"))
    }

    fileprivate func streamStopped(_ error: any Error) {
        queue.async { [self] in
            guard !finished, !interrupted else { return }
            interrupted = true
            callbacks.interrupted(error)
        }
    }

    /// The display's filter again, now that Margin's ordinary windows have changed (Settings opened): they stay in the
    /// recording, as in screenshots.
    func update(_ filter: SCContentFilter) {
        stream.updateContentFilter(filter) { error in
            if let error { CaptureLog.capture.error("recording filter not updated: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: Stopping

    /// The numbers so far (for the DEBUG state dump).
    func currentStats() async -> Stats {
        await withCheckedContinuation { c in queue.async { [self] in c.resume(returning: stats) } }
    }

    /// Stops capturing and finishes the file: the last frame is held until the stop, and the index is written. `at` is when
    /// the stop was asked for, on the host clock the frames are stamped with.
    func stop(at end: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) async -> Outcome {
        try? await stream.stopCapture()
        return await withCheckedContinuation { (c: CheckedContinuation<Outcome, Never>) in
            queue.async { [self] in finish(at: end) { c.resume(returning: $0) } }
        }
    }

    private func finish(at requested: CMTime, done: @escaping @Sendable (Outcome) -> Void) {
        finished = true
        guard let first = firstTime, writer.status == .writing, stats.framesWritten > 0 else {
            let error = writer.error?.localizedDescription ?? "Nothing was recorded"
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            done(Outcome(url: nil, duration: 0, framesWritten: stats.framesWritten, framesDropped: stats.framesDropped,
                         error: error))
            return
        }
        // Not past the last frame by more than the stop's own delay when the stream stopped by itself earlier.
        var end = CMTimeMaximum(requested, lastTime)
        if interrupted { end = lastTime }
        if let lastFrame, CMTimeSubtract(end, lastTime).seconds > 1 / Double(source.fps),
           let tail = try? CMSampleBuffer(copying: lastFrame, withNewTiming: [
               CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: end, decodeTimeStamp: .invalid),
           ]), video.isReadyForMoreMediaData, video.append(tail) {
            lastTime = end
        }
        self.lastFrame = nil
        for input in [video, audio, mic].compactMap({ $0 }) { input.markAsFinished() }
        writer.endSession(atSourceTime: end)
        let stats = stats
        let duration = max(0, CMTimeSubtract(end, first).seconds)
        writer.finishWriting { [self] in
            let ok = writer.status == .completed
            if !ok { try? FileManager.default.removeItem(at: url) }
            done(Outcome(url: ok ? url : nil, duration: duration, framesWritten: stats.framesWritten,
                         framesDropped: stats.framesDropped,
                         error: ok ? nil : writer.error?.localizedDescription ?? "The file couldn’t be finished"))
        }
    }

    enum RecorderError: LocalizedError {
        /// The file couldn't be created where it was asked for.
        case file(String)
        /// Less than `RecordingFiles.minimumFreeBytes` is free there.
        case full
        case failed(String)

        /// Another folder might do (the Unsaved one).
        var isAboutTheFolder: Bool {
            switch self {
            case .file, .full: true
            case .failed: false
            }
        }

        var errorDescription: String? {
            switch self {
            case .file(let why), .failed(let why): why
            case .full: "The disk is almost full"
            }
        }
    }
}

/// `SCStream`'s delegate, made before the recorder that it reports to.
private final class DelegateForwarder: NSObject, SCStreamDelegate, @unchecked Sendable {
    weak var recorder: ScreenRecorder?

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        recorder?.streamStopped(error)
    }
}
