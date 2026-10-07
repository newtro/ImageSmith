import AppKit
import AVFoundation

enum VideoEditError: LocalizedError {
    case noVideo
    case invalidDuration
    case exportUnavailable
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noVideo: "This file has no video track."
        case .invalidDuration: "This recording has no playable duration."
        case .exportUnavailable: "MP4 export is unavailable for this recording."
        case .exportFailed: "The edited recording could not be exported."
        }
    }
}

@MainActor
enum VideoEditExporter {
    static func composition(asset: AVURLAsset, plan: VideoEditPlan) async throws -> AVMutableComposition {
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoEditError.noVideo
        }
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoEditError.noVideo
        }
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let audio: AVMutableCompositionTrack? = plan.muted || sourceAudio == nil ? nil
            : composition.addMutableTrack(withMediaType: .audio,
                                          preferredTrackID: kCMPersistentTrackID_Invalid)
        var destination = CMTime.zero
        for segment in plan.segments {
            let range = CMTimeRange(start: CMTime(seconds: segment.start, preferredTimescale: 600),
                                    duration: CMTime(seconds: segment.duration, preferredTimescale: 600))
            // A sliver shorter than one tick rounds to zero, and inserting it throws.
            guard range.duration > .zero else { continue }
            try video.insertTimeRange(range, of: sourceVideo, at: destination)
            if let sourceAudio, let audio {
                try audio.insertTimeRange(range, of: sourceAudio, at: destination)
            }
            destination = CMTimeAdd(destination, range.duration)
        }
        if plan.rate != 1 {
            composition.scaleTimeRange(CMTimeRange(start: .zero, duration: destination),
                                       toDuration: CMTime(seconds: plan.duration, preferredTimescale: 600))
        }
        return composition
    }

    static func export(asset: AVURLAsset, plan: VideoEditPlan, to url: URL) async throws {
        let composition = try await composition(asset: asset, plan: plan)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality),
              session.supportedFileTypes.contains(.mp4) else {
            throw VideoEditError.exportUnavailable
        }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".imagesmith-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        session.outputURL = temporary
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        let box = VideoExportSessionBox(session)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.value.exportAsynchronously {
                if box.value.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: box.value.error ?? VideoEditError.exportFailed) }
            }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    static func poster(for url: URL) -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// The exporter callback runs after AVFoundation owns its async session.
private final class VideoExportSessionBox: @unchecked Sendable {
    let value: AVAssetExportSession
    init(_ value: AVAssetExportSession) { self.value = value }
}
