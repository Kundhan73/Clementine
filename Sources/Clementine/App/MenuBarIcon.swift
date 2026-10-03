import AppKit

/// The monochrome template image shown in the menu bar: a round fruit with a
/// leaf and two little arrows inside (the "convert" cycle).
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Clementine"
        return image
    }

    static func draw() {
        NSColor.black.set()
        let center = NSPoint(x: 9, y: 7.6)
        let body = NSBezierPath(ovalIn: NSRect(x: center.x - 6.6, y: center.y - 6.6, width: 13.2, height: 13.2))
        body.lineWidth = 1.5
        body.stroke()

        let leaf = NSBezierPath()
        leaf.move(to: NSPoint(x: 9.2, y: 14.0))
        leaf.curve(to: NSPoint(x: 15.6, y: 17.2), controlPoint1: NSPoint(x: 10.2, y: 17.0), controlPoint2: NSPoint(x: 13.6, y: 17.9))
        leaf.curve(to: NSPoint(x: 9.2, y: 14.0), controlPoint1: NSPoint(x: 14.8, y: 15.0), controlPoint2: NSPoint(x: 11.6, y: 13.8))
        leaf.fill()

        // Two arcs chasing each other.
        let r: CGFloat = 3.3
        for start in [CGFloat(40), CGFloat(220)] {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: r, startAngle: start, endAngle: start + 110, clockwise: false)
            arc.lineWidth = 1.3
            arc.lineCapStyle = .round
            arc.stroke()
            let th = (start + 118) * .pi / 180
            let radial = NSPoint(x: cos(th), y: sin(th)), tangent = NSPoint(x: -sin(th), y: cos(th))
            let base = NSPoint(x: center.x + radial.x * r, y: center.y + radial.y * r)
            let head = NSBezierPath()
            head.move(to: NSPoint(x: base.x + radial.x * 1.7, y: base.y + radial.y * 1.7))
            head.line(to: NSPoint(x: base.x + tangent.x * 2.0, y: base.y + tangent.y * 2.0))
            head.line(to: NSPoint(x: base.x - radial.x * 1.7, y: base.y - radial.y * 1.7))
            head.close()
            head.fill()
        }
    }
}
