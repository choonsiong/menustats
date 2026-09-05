import Cocoa

/// A compact history graph drawn inside a menu item.
final class SparklineView: NSView {

    struct Series {
        var values: [Double]
        var color: NSColor
    }

    var series: [Series] = [] { didSet { needsDisplay = true } }
    var maxValue: Double = 100 { didSet { needsDisplay = true } }
    var capacity: Int = 60
    var caption: String = "" { didSet { needsDisplay = true } }
    var readout: String = "" { didSet { needsDisplay = true } }

    private let horizontalInset: CGFloat = 20
    private let verticalInset: CGFloat = 4

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let plot = bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        guard plot.width > 10, plot.height > 10 else { return }

        let background = NSBezierPath(roundedRect: plot, xRadius: 5, yRadius: 5)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.10).setFill()
        background.fill()

        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        for fraction in [0.25, 0.5, 0.75] {
            let y = plot.minY + plot.height * CGFloat(fraction)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y))
            line.line(to: NSPoint(x: plot.maxX, y: y))
            line.lineWidth = 0.5
            line.stroke()
        }

        let ceiling = max(maxValue, 0.0001)
        let step = plot.width / CGFloat(max(1, capacity - 1))

        for line in series {
            guard line.values.count > 1 else { continue }

            let points: [NSPoint] = line.values.enumerated().map { index, value in
                let offset = CGFloat(line.values.count - 1 - index) * step
                let x = max(plot.minX, plot.maxX - offset)
                let ratio = CGFloat(max(0, min(1, value / ceiling)))
                return NSPoint(x: x, y: plot.minY + ratio * (plot.height - 2) + 1)
            }

            let fill = NSBezierPath()
            fill.move(to: NSPoint(x: points[0].x, y: plot.minY))
            points.forEach { fill.line(to: $0) }
            fill.line(to: NSPoint(x: points[points.count - 1].x, y: plot.minY))
            fill.close()
            line.color.withAlphaComponent(0.18).setFill()
            fill.fill()

            let stroke = NSBezierPath()
            stroke.move(to: points[0])
            points.dropFirst().forEach { stroke.line(to: $0) }
            stroke.lineWidth = 1.5
            stroke.lineJoinStyle = .round
            line.color.setStroke()
            stroke.stroke()
        }

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        if !caption.isEmpty {
            let text = NSAttributedString(string: caption, attributes: labelAttributes)
            text.draw(at: NSPoint(x: plot.minX + 5, y: plot.maxY - text.size().height - 3))
        }

        if !readout.isEmpty {
            let text = NSAttributedString(string: readout, attributes: labelAttributes)
            let size = text.size()
            text.draw(at: NSPoint(x: plot.maxX - size.width - 5, y: plot.maxY - size.height - 3))
        }
    }
}
