import CoreGraphics
import Foundation

/// Turns the server's stored peaks into bars for a given width. Everything here is
/// real audio data: nothing invents a bar, and no data means no bars.
enum WaveformDisplay {
    /// Whether there is anything to draw. Silence is real and draws low bars; an
    /// empty list means the server has not computed peaks for this item yet.
    static func hasData(_ peaks: [Int]?) -> Bool {
        peaks?.isEmpty == false
    }

    static func barCount(width: CGFloat, barWidth: CGFloat, spacing: CGFloat) -> Int {
        let step = barWidth + spacing
        guard width.isFinite, width >= barWidth, step > 0 else { return 0 }
        return Int((width + spacing) / step)
    }

    /// One level from 0 to 1 per bar. Shrinking keeps each bucket's loudest peak, so a
    /// short burst stays visible; stretching repeats the nearest peak. Anything outside
    /// 0 to 100 is clamped rather than trusted.
    static func levels(from peaks: [Int], barCount: Int) -> [CGFloat] {
        guard barCount > 0, !peaks.isEmpty else { return [] }
        return (0..<barCount).map { bar in
            let start = bar * peaks.count / barCount
            let end = max(start + 1, (bar + 1) * peaks.count / barCount)
            let loudest = peaks[start..<min(end, peaks.count)].max() ?? 0
            return CGFloat(min(100, max(0, loudest))) / 100
        }
    }

    /// The part of a track a touch at `x` selects, from 0 to 1.
    static func fraction(atX x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(1, max(0, x / width))
    }
}

/// The recent levels from the recorder's real meter, newest last. Linear amplitude
/// would leave speech near the floor, so levels are shown on a decibel scale.
struct LiveLevelMeter: Equatable {
    static let capacity = 64
    /// Quieter than this draws as the floor. Normal speech sits around -30 dB.
    static let floorDecibels: CGFloat = -50

    private(set) var levels: [CGFloat] = []

    mutating func append(linearLevel: CGFloat) {
        levels.append(Self.displayLevel(linearLevel: linearLevel))
        if levels.count > Self.capacity {
            levels.removeFirst(levels.count - Self.capacity)
        }
    }

    static func displayLevel(linearLevel: CGFloat) -> CGFloat {
        guard linearLevel.isFinite, linearLevel > 0 else { return 0 }
        let decibels = 20 * log10(linearLevel)
        return min(1, max(0, (decibels - floorDecibels) / -floorDecibels))
    }
}

extension Array where Element == MediaSegment {
    /// The segment playing at `time`, for transcript highlighting. Segments arrive in
    /// order, and a long recording has thousands, so this searches rather than scans.
    /// A segment with no times, such as a PDF page, is never highlighted, and is stepped
    /// over. Nothing is highlighted in a silent gap after a segment has ended.
    func activeSegmentIndex(at time: TimeInterval) -> Int? {
        guard time.isFinite, time >= 0 else { return nil }
        let milliseconds = Int64(time * 1_000)
        var low = 0
        var high = count - 1
        var match: Int?
        while low <= high {
            // Step left to the nearest timed segment in this range.
            var middle = (low + high) / 2
            while middle >= low, self[middle].startMs == nil {
                middle -= 1
            }
            guard middle >= low, let start = self[middle].startMs else {
                low = (low + high) / 2 + 1
                continue
            }
            if start <= milliseconds {
                match = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard let match else { return nil }
        if let end = self[match].endMs, milliseconds >= end { return nil }
        return match
    }
}
