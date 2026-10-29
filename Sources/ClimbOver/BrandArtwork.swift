import AppKit

enum ClimbOverArtwork {
    enum State { case stopped, connected, working, warning, external }

    // One continuous route crosses two summits. Coordinates are normalized, with origin at bottom left.
    static func route(in rect: NSRect) -> NSBezierPath {
        let points: [NSPoint] = [NSPoint(x: 0.10, y: 0.19), NSPoint(x: 0.36, y: 0.67),
            NSPoint(x: 0.55, y: 0.33), NSPoint(x: 0.88, y: 0.83)]
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + points[0].x * rect.width, y: rect.minY + points[0].y * rect.height))
        for point in points.dropFirst() {
            path.line(to: NSPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height))
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    static func menuImage(state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let line = route(in: NSRect(x: 0, y: 2, width: 19, height: 16))
            line.lineWidth = state == .connected ? 2.15 : 1.7
            line.stroke()
            let badge = NSRect(x: 14.5, y: 1.5, width: 3.5, height: 3.5)
            switch state {
            case .connected: NSBezierPath(ovalIn: badge).fill()
            case .working:
                for x in [10.0, 13.0, 16.0] { NSBezierPath(ovalIn: NSRect(x: x, y: 1.5, width: 1.4, height: 1.4)).fill() }
            case .warning:
                let alert = NSBezierPath()
                alert.move(to: NSPoint(x: 16.5, y: 5))
                alert.line(to: NSPoint(x: 16.5, y: 3))
                alert.lineWidth = 1.6
                alert.stroke()
                NSBezierPath(ovalIn: NSRect(x: 15.8, y: 0.8, width: 1.4, height: 1.4)).fill()
            case .external:
                let ring = NSBezierPath(ovalIn: badge)
                ring.lineWidth = 1.1
                ring.stroke()
            case .stopped: break
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ClimbOver"
        return image
    }

    static func drawAppIcon(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: rect.width / 1024)
        transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 184, yRadius: 184)
        // This flattened ICNS targets macOS 13+. Future Icon Composer layers can reuse the route.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        NSColor(calibratedRed: 0.04, green: 0.15, blue: 0.24, alpha: 1).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        let background = NSGradient(colors: [
            NSColor(srgbRed: 0.025, green: 0.17, blue: 0.29, alpha: 1),
            NSColor(srgbRed: 0.06, green: 0.36, blue: 0.56, alpha: 1)
        ])!
        background.draw(in: tile, angle: 55)
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        // A quiet ridge gives the route a landscape without adding detail at small sizes.
        let ridge = NSBezierPath()
        ridge.move(to: NSPoint(x: 70, y: 100))
        ridge.line(to: NSPoint(x: 428, y: 607))
        ridge.line(to: NSPoint(x: 760, y: 100))
        ridge.close()
        NSColor(srgbRed: 0.53, green: 0.83, blue: 0.92, alpha: 0.08).setFill()
        ridge.fill()
        NSGraphicsContext.restoreGraphicsState()
        let mark = route(in: NSRect(x: 212, y: 245, width: 600, height: 540))
        mark.lineWidth = 78
        NSColor(srgbRed: 0.96, green: 0.99, blue: 1, alpha: 1).setStroke()
        mark.stroke()
    }
}
