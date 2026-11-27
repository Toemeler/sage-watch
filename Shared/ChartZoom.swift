import Foundation

/// Zoom and pan of one chart axis, kept apart from the views so it can be tested. A range never leaves the full
/// range and never gets narrower than `minSpan`; zooming keeps the point under the fingers where it is.
enum ChartZoom {
    /// `range` scaled by `scale` (> 1 zooms in) around `anchor` (0 = lower end of the visible range, 1 = upper)
    static func zoom(_ range: ClosedRange<Double>, full: ClosedRange<Double>, scale: Double, anchor: Double,
                     minSpan: Double) -> ClosedRange<Double> {
        guard scale.isFinite, scale > 0 else { return range }
        let span = range.upperBound - range.lowerBound
        let fullSpan = full.upperBound - full.lowerBound
        let newSpan = min(fullSpan, max(minSpan, span / scale))
        let a = min(1, max(0, anchor))
        let pivot = range.lowerBound + span * a
        return clamp(pivot - newSpan * a, span: newSpan, full: full)
    }

    /// `range` moved by `fraction` of its own width (positive: toward the upper end)
    static func pan(_ range: ClosedRange<Double>, full: ClosedRange<Double>, fraction: Double) -> ClosedRange<Double> {
        let span = range.upperBound - range.lowerBound
        return clamp(range.lowerBound + span * fraction, span: span, full: full)
    }

    private static func clamp(_ lower: Double, span: Double, full: ClosedRange<Double>) -> ClosedRange<Double> {
        let lo = min(max(lower, full.lowerBound), full.upperBound - span)
        return lo...(lo + span)
    }

    /// at most `limit` points of a time series inside `range` (every n-th), so a zoomed-out day stays fast and a
    /// zoomed-in hour shows every sample
    static func thin<T>(_ points: [(Double, T)], in range: ClosedRange<Double>, limit: Int = 900) -> [(Double, T)] {
        let inside = points.filter { range.contains($0.0) }
        guard inside.count > limit, limit > 0 else { return inside }
        let step = Int((Double(inside.count) / Double(limit)).rounded(.up))
        return stride(from: 0, to: inside.count, by: step).map { inside[$0] }
    }
}
