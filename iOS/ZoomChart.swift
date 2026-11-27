import SwiftUI
import UIKit

/// Two-finger pinch that zooms each axis on its own: fingers spread sideways zoom time, spread up and down zoom the
/// values, diagonally both. One finger pans, a double tap goes back to the whole day. (SwiftUI's MagnifyGesture
/// gives one scale for both directions, so this reads the two touches itself.)
struct AxisPinchPan: UIViewRepresentable {
    /// scale x, scale y (> 1 = in), anchor x 0...1 from the left, anchor y 0...1 from the bottom
    var onZoom: (Double, Double, Double, Double) -> Void
    /// pan in fractions of the visible width / height (positive: toward later / higher values)
    var onPan: (Double, Double) -> Void
    var onReset: () -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.numberOfTapsRequired = 2
        [pinch, pan, tap].forEach { v.addGestureRecognizer($0) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: AxisPinchPan
        private var lastDX: CGFloat = 0, lastDY: CGFloat = 0
        private var lastPan: CGPoint = .zero
        init(parent: AxisPinchPan) { self.parent = parent }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let v = g.view, g.numberOfTouches == 2 else { return }
            let a = g.location(ofTouch: 0, in: v), b = g.location(ofTouch: 1, in: v)
            let dx = abs(a.x - b.x), dy = abs(a.y - b.y)
            if g.state == .began { lastDX = dx; lastDY = dy; return }
            guard g.state == .changed else { return }
            // an axis only zooms when the fingers are really spread along it (40 pt), so a sideways pinch does not
            // also jitter the values
            let sx = lastDX > 40 && dx > 40 ? Double(dx / lastDX) : 1
            let sy = lastDY > 40 && dy > 40 ? Double(dy / lastDY) : 1
            lastDX = dx; lastDY = dy
            let c = g.location(in: v)
            parent.onZoom(sx, sy, Double(c.x / max(v.bounds.width, 1)), Double(1 - c.y / max(v.bounds.height, 1)))
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            let t = g.translation(in: v)
            if g.state == .began { lastPan = .zero }
            let d = CGPoint(x: t.x - lastPan.x, y: t.y - lastPan.y)
            lastPan = t
            // dragging right shows earlier times; dragging down shows higher values (content follows the finger)
            parent.onPan(Double(-d.x / max(v.bounds.width, 1)), Double(d.y / max(v.bounds.height, 1)))
        }

        @objc func tap(_ g: UITapGestureRecognizer) { parent.onReset() }
    }
}

/// One of the day's charts on the whole screen, zoomable in time and value.
struct ZoomChartScreen<ChartView: View>: View {
    let title: String
    let fullX: ClosedRange<Date>
    /// nil: a chart without a value axis to zoom (the activity rows)
    let fullY: ClosedRange<Double>?
    let minSpanY: Double
    @ViewBuilder let chart: (ClosedRange<Date>, ClosedRange<Double>?) -> ChartView

    @Environment(\.dismiss) private var dismiss
    @State private var x: ClosedRange<Double>?
    @State private var y: ClosedRange<Double>?

    private var fullXd: ClosedRange<Double> { fullX.lowerBound.timeIntervalSince1970...fullX.upperBound.timeIntervalSince1970 }
    private var visibleX: ClosedRange<Double> { x ?? fullXd }
    private var visibleY: ClosedRange<Double>? { y ?? fullY }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(spanText).font(.caption).foregroundStyle(Theme.muted)
                chart(Date(timeIntervalSince1970: visibleX.lowerBound)...Date(timeIntervalSince1970: visibleX.upperBound), visibleY)
                    .overlay {
                        AxisPinchPan(onZoom: zoom, onPan: pan, onReset: reset)
                            .accessibilityHidden(true)
                    }
                Text("Pinch sideways to zoom time, up and down to zoom values · drag to move · double-tap for the whole day")
                    .font(.caption2).foregroundStyle(Theme.muted)
            }
            .padding(16)
            .background(Theme.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Reset") { reset() }.disabled(x == nil && y == nil) }
            }
            // VoiceOver and anyone who prefers buttons: zoom time in and out around the middle
            .accessibilityAction(named: Text("Zoom in")) { zoom(2, 1, 0.5, 0.5) }
            .accessibilityAction(named: Text("Zoom out")) { zoom(0.5, 1, 0.5, 0.5) }
        }
        .preferredColorScheme(.dark)
    }

    private var spanText: String {
        let f = Date.FormatStyle().hour().minute()
        let a = Date(timeIntervalSince1970: visibleX.lowerBound), b = Date(timeIntervalSince1970: visibleX.upperBound)
        return "\(a.formatted(f)) – \(b.formatted(f))"
    }

    private func zoom(_ sx: Double, _ sy: Double, _ ax: Double, _ ay: Double) {
        x = ChartZoom.zoom(visibleX, full: fullXd, scale: sx, anchor: ax, minSpan: 10 * 60)
        if let fy = fullY, let vy = visibleY, sy != 1 {
            y = ChartZoom.zoom(vy, full: fy, scale: sy, anchor: ay, minSpan: minSpanY)
        }
    }

    private func pan(_ fx: Double, _ fy: Double) {
        x = ChartZoom.pan(visibleX, full: fullXd, fraction: fx)
        if let full = fullY, let vy = visibleY { y = ChartZoom.pan(vy, full: full, fraction: fy) }
    }

    private func reset() {
        withAnimation(.easeOut(duration: 0.25)) { x = nil; y = nil }
    }
}
