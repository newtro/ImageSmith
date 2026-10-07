import Foundation

/// Source intervals retained in an edited recording. Times in the UI refer to
/// the assembled timeline, while each segment refers to the original file.
struct VideoSegment: Equatable {
    var start: Double
    var end: Double
    var duration: Double { end - start }
}

struct VideoEditPlan: Equatable {
    let originalDuration: Double
    private(set) var segments: [VideoSegment]
    var muted = false
    var rate = 1.0

    init(duration: Double) {
        originalDuration = max(0, duration)
        segments = duration > 0 ? [VideoSegment(start: 0, end: duration)] : []
    }

    /// One frame at the composition timescale; shorter slices round to a zero
    /// CMTime and make insertTimeRange throw.
    static let minimumSegment = 1.0 / 600

    var sourceTimelineDuration: Double { segments.reduce(0) { $0 + $1.duration } }
    var duration: Double { sourceTimelineDuration / rate }
    var hasEdits: Bool {
        muted || rate != 1 || segments != [VideoSegment(start: 0, end: originalDuration)]
    }

    mutating func trim(from inPoint: Double, to outPoint: Double) {
        let lower = max(0, min(duration, inPoint))
        let upper = max(lower, min(duration, outPoint))
        guard upper - lower >= 0.05 else { return }
        segments = slices(from: lower * rate, to: upper * rate)
    }

    mutating func cut(from inPoint: Double, to outPoint: Double) {
        let lower = max(0, min(duration, inPoint))
        let upper = max(lower, min(duration, outPoint))
        guard upper - lower >= 0.05, duration - (upper - lower) >= 0.05 else { return }
        segments = slices(from: 0, to: lower * rate)
            + slices(from: upper * rate, to: sourceTimelineDuration)
    }

    mutating func split(at time: Double) {
        let sourceTime = time * rate
        guard sourceTime > 0.001, sourceTime < sourceTimelineDuration - 0.001 else { return }
        var cursor = 0.0
        for index in segments.indices {
            let segment = segments[index]
            let local = sourceTime - cursor
            if local > 0.001, local < segment.duration - 0.001 {
                let boundary = segment.start + local
                segments.replaceSubrange(index...index, with: [
                    VideoSegment(start: segment.start, end: boundary),
                    VideoSegment(start: boundary, end: segment.end)
                ])
                return
            }
            cursor += segment.duration
        }
    }

    /// Plain bounds rather than a Range: at 1.5x, duration * rate can land one
    /// ulp past sourceTimelineDuration, and an inverted Range traps.
    private func slices(from lower: Double, to upper: Double) -> [VideoSegment] {
        let lower = min(lower, sourceTimelineDuration)
        let upper = min(upper, sourceTimelineDuration)
        guard upper > lower else { return [] }
        var cursor = 0.0
        var result: [VideoSegment] = []
        for segment in segments {
            let overlapStart = max(cursor, lower)
            let overlapEnd = min(cursor + segment.duration, upper)
            if overlapEnd - overlapStart > VideoEditPlan.minimumSegment {
                result.append(VideoSegment(start: segment.start + overlapStart - cursor,
                                           end: segment.start + overlapEnd - cursor))
            }
            cursor += segment.duration
        }
        return result
    }
}
