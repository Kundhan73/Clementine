#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Geometry of the wheel: a hub in the middle and up to two rings of chips,
/// starting at 12 o'clock and going clockwise. Coordinates are relative to
/// the wheel centre, y up.
public struct WheelLayout {
    public enum Hit: Equatable, Sendable {
        case hub
        case chip(Int)
        case none
    }

    public static let maxPerRing = 12

    public let count: Int
    public let scale: CGFloat
    /// Tool chips carry an icon and a label, so they're a little bigger.
    public let largeChips: Bool

    public init(count: Int, scale: CGFloat = 1, largeChips: Bool = false) {
        self.count = count
        self.scale = scale
        self.largeChips = largeChips
    }

    public var hubRadius: CGFloat { 46 * scale }
    public var chipRadius: CGFloat { (largeChips ? 31 : 27) * scale }
    public var innerCount: Int { min(count, Self.maxPerRing) }
    public var outerCount: Int { max(0, count - Self.maxPerRing) }

    public var innerRadius: CGFloat {
        let gap: CGFloat = 10 * scale
        let needed = CGFloat(max(innerCount, 1)) * (2 * chipRadius + gap) / (2 * .pi)
        return max(hubRadius + chipRadius + 20 * scale, needed)
    }

    public var outerRadius: CGFloat { innerRadius + 2 * chipRadius + 14 * scale }

    /// Radius of the frosted disc behind everything.
    public var discRadius: CGFloat {
        (outerCount > 0 ? outerRadius : innerRadius) + chipRadius + 12 * scale
    }

    /// Side of a square that fits the disc plus hover growth and a margin.
    public var canvasSide: CGFloat { ceil(2 * (discRadius + 16 * scale)) }

    /// Angle (radians, y-up) of chip `index`.
    public func angle(of index: Int) -> CGFloat {
        if index < innerCount {
            return .pi / 2 - 2 * .pi * CGFloat(index) / CGFloat(innerCount)
        }
        let i = index - innerCount
        let step = 2 * .pi / CGFloat(outerCount)
        return .pi / 2 - step * CGFloat(i) - step / 2
    }

    public func center(of index: Int) -> CGPoint {
        let r = index < innerCount ? innerRadius : outerRadius
        let a = angle(of: index)
        return CGPoint(x: cos(a) * r, y: sin(a) * r)
    }

    /// Generous hit-testing by ring band and angular sector, so a chip is easy
    /// to hit even when the pointer is between chips.
    public func hitTest(_ p: CGPoint) -> Hit {
        let r = hypot(p.x, p.y)
        if r <= hubRadius + 4 * scale { return .hub }
        guard count > 0 else { return .none }
        let innerBand = (innerRadius - chipRadius - 14 * scale)...(innerRadius + chipRadius + 6 * scale)
        let split = (innerRadius + outerRadius) / 2
        let a = atan2(p.y, p.x)
        if outerCount > 0, r > split, r <= outerRadius + chipRadius + 10 * scale {
            return .chip(innerCount + nearest(angle: a, count: outerCount, offset: 0.5))
        }
        if innerBand.contains(r) || (outerCount > 0 && r > innerBand.upperBound && r <= split) {
            return .chip(nearest(angle: a, count: innerCount, offset: 0))
        }
        return .none
    }

    /// Index whose angle is closest to `angle` on a ring of `count` chips.
    private func nearest(angle: CGFloat, count: Int, offset: CGFloat) -> Int {
        let step = 2 * .pi / CGFloat(count)
        // Clockwise distance from 12 o'clock, in steps.
        var t = (.pi / 2 - angle) / step - offset
        t = t.truncatingRemainder(dividingBy: CGFloat(count))
        if t < 0 { t += CGFloat(count) }
        return Int(t.rounded()) % count
    }
}
