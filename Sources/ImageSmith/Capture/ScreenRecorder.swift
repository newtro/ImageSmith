import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreImage

enum RecordingTarget {
    case display(CGDirectDisplayID, CGFloat)
    case window(WindowInfo, CGFloat)
    case region(CGDirectDisplayID, CGFloat, CGRect, screenFrame: CGRect) // Cocoa rectangles on one display
}

/// Settings captured on the main actor; `start` runs off it and must not read
/// AppKit or the settings store itself.
struct RecordingOptions {
    var includeCursor: Bool
    var systemAudio: Bool
    var downscaleRetina: Bool
    var includeWindowShadow: Bool
}

/// Writes ScreenCaptureKit frames directly to an MP4. All writer access stays on
/// the serial sample queue, including the final flush when capture stops.
final class ScreenRecorder: NSObject, SCStreamOutput {
    let url: URL
    private let stream: SCStream
    private let streamDelegate: RecordingStreamDelegate
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let sampleQueue = DispatchQueue(label: "ImageSmith.recording.samples")
    private var startedSession = false
    private var poster: NSImage?
    private var lastVideoFrame: CMSampleBuffer?
    private var finished = false
    private let ciContext = CIContext()
    var onUnexpectedStop: ((Error) -> Void)?

    private init(url: URL, stream: SCStream, streamDelegate: RecordingStreamDelegate, writer: AVAssetWriter,
                 video: AVAssetWriterInput, audio: AVAssetWriterInput?) {
        self.url = url
        self.stream = stream
        self.streamDelegate = streamDelegate
        self.writer = writer
        self.video = video
        self.audio = audio
        super.init()
    }

    static func start(target: RecordingTarget, url: URL,
                      options: RecordingOptions) async throws -> ScreenRecorder {
        let includeCursor = options.includeCursor
        let systemAudio = options.systemAudio
        guard ScreenCapturer.hasPermission() else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        let pointSize: CGSize
        let scale: CGFloat
        switch target {
        case .display(let id, let s):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError.noDisplay
            }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            filter = SCContentFilter(display: display,
                                     excludingApplications: content.applications.filter { $0.processID == ownPID },
                                     exceptingWindows: [])
            pointSize = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
            scale = s
        case .window(let info, let s):
            filter = SCContentFilter(desktopIndependentWindow: info.scWindow)
            pointSize = info.frame.size
            scale = s
            config.ignoreShadowsSingleWindow = !options.includeWindowShadow
        case .region(let id, let s, let selected, let screenFrame):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError.noDisplay
            }
            let rect = selected.intersection(screenFrame)
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else {
                throw CaptureError.failed("The selected region is not on a display.")
            }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            filter = SCContentFilter(display: display,
                                     excludingApplications: content.applications.filter { $0.processID == ownPID },
                                     exceptingWindows: [])
            config.sourceRect = CGRect(x: rect.minX - screenFrame.minX,
                                       y: screenFrame.maxY - rect.maxY,
                                       width: rect.width, height: rect.height)
            pointSize = rect.size
            scale = s
        }

        // H.264 requires even dimensions. Video defaults to 30 fps, at native
        // display resolution unless the same Retina downscale option is enabled.
        let effectiveScale = options.downscaleRetina ? 1 : scale
        let width = max(2, Int((pointSize.width * effectiveScale).rounded()) & ~1)
        let height = max(2, Int((pointSize.height * effectiveScale).rounded()) & ~1)
        config.width = width
        config.height = height
        config.scalesToFit = false
        config.showsCursor = includeCursor
        config.captureResolution = .best
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6   // one buffer stays held as the stop-time repeat frame
        config.capturesAudio = systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: min(18_000_000, width * height * 4)]
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        var audio: AVAssetWriterInput?
        if systemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audio = input
        }
        guard writer.startWriting() else {
            throw writer.error ?? CaptureError.failed("Could not start the video writer.")
        }
        let delegate = RecordingStreamDelegate()
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        let recorder = ScreenRecorder(url: url, stream: stream, streamDelegate: delegate,
                                      writer: writer, video: video, audio: audio)
        delegate.recorder = recorder
        do {
            try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.sampleQueue)
            if systemAudio { try stream.addStreamOutput(recorder, type: .audio, sampleHandlerQueue: recorder.sampleQueue) }
            try await stream.startCapture()
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return recorder
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, !finished, writer.status == .writing else { return }
        switch type {
        case .screen:
            guard let imageBuffer = sampleBuffer.imageBuffer else { return }
            if !startedSession {
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                startedSession = true
            }
            if poster == nil,
               let cg = ciContext.createCGImage(CIImage(cvPixelBuffer: imageBuffer),
                                                from: CGRect(x: 0, y: 0,
                                                             width: CVPixelBufferGetWidth(imageBuffer),
                                                             height: CVPixelBufferGetHeight(imageBuffer))) {
                poster = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            if video.isReadyForMoreMediaData, video.append(sampleBuffer) { lastVideoFrame = sampleBuffer }
        case .audio:
            if startedSession, let audio, audio.isReadyForMoreMediaData { audio.append(sampleBuffer) }
        default: break
        }
    }

    func stop() async throws -> NSImage {
        // A stream may already have stopped because of a display disconnect.
        // The file still needs to be finalized in that case.
        try? await stream.stopCapture()
        let image = sampleQueue.sync { () -> NSImage? in
            finished = true
            guard startedSession else { return nil }
            // ScreenCaptureKit only sends frames when content changes, so a static
            // display may yield a single frame. endSession alone does not stretch
            // that frame, so repeat the last one at stop time.
            let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
            if let last = lastVideoFrame, CMTimeCompare(stopTime, last.presentationTimeStamp) > 0 {
                var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: stopTime,
                                                decodeTimeStamp: .invalid)
                var copy: CMSampleBuffer?
                if CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: last,
                                                         sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                         sampleBufferOut: &copy) == noErr,
                   let copy, video.isReadyForMoreMediaData {
                    video.append(copy)
                }
            }
            lastVideoFrame = nil
            writer.endSession(atSourceTime: stopTime)
            video.markAsFinished()
            audio?.markAsFinished()
            return poster
        }
        guard let image else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.failed("The recording ended before the first frame arrived.")
        }
        let writer = WriterCompletionBox(self.writer)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.value.finishWriting {
                    if writer.value.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: writer.value.error ?? CaptureError.failed("Could not finish the recording.")) }
                }
            }
        } catch {
            // A writer that failed never wrote the MP4 index, so the file
            // cannot be played; don't leave it in the captures folder.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return image
    }
}

/// The finish callback runs after all stream output has stopped and all writer
/// inputs have been marked finished. AVFoundation owns the remaining transition.
private final class WriterCompletionBox: @unchecked Sendable {
    let value: AVAssetWriter
    init(_ value: AVAssetWriter) { self.value = value }
}

private final class RecordingStreamDelegate: NSObject, SCStreamDelegate {
    weak var recorder: ScreenRecorder?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.recorder?.onUnexpectedStop?(error) }
    }
}
