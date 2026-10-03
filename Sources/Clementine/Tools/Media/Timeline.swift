import AppKit
import ClementineCore
import SwiftUI

/// Converts between timeline x positions and seconds.
struct TimelineScale {
    let width: CGFloat
    let duration: Double

    func x(_ t: Double) -> CGFloat { duration > 0 ? CGFloat(t / duration) * width : 0 }
    func t(_ x: CGFloat) -> Double { width > 0 ? min(max(0, Double(x / width) * duration), duration) : 0 }
}

/// Thumbnails or a waveform with a playhead. Optionally: an in/out
/// selection (Trim), markers (Split), intervals created by dragging
/// (Bleep), and read-only ranges (Video Redact).
struct Timeline: View {
    @ObservedObject var session: MediaSession
    var selection: Binding<ClosedRange<Double>>?
    var markers: Binding<[Double]>?
    var intervals: Binding<[ClosedRange<Double>]>?
    var selectedInterval: Binding<Int?>?
    /// Cut points shown without editing (Split by parts).
    var cuts: [Double] = []
    var ranges: [(range: ClosedRange<Double>, highlighted: Bool)] = []
    var height: CGFloat = 56

    enum Drag: Equatable {
        case scrub, inPoint, outPoint, marker(Int), newInterval(Double)
    }

    @State var drag: Drag?
    @State var draft: ClosedRange<Double>?

    var body: some View {
        GeometryReader { geo in
            let scale = TimelineScale(width: max(1, geo.size.width), duration: session.duration)
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                strip(width: scale.width, height: h)
                ForEach(Array(ranges.enumerated()), id: \.offset) { _, entry in
                    let x0 = scale.x(entry.range.lowerBound), x1 = scale.x(min(entry.range.upperBound, session.duration))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(entry.highlighted ? 0.9 : 0.45))
                        .frame(width: max(2, x1 - x0), height: 5)
                        .offset(x: x0, y: h - 7)
                }
                if let intervals {
                    ForEach(Array(intervals.wrappedValue.enumerated()), id: \.offset) { index, r in
                        let selected = selectedInterval?.wrappedValue == index
                        Rectangle()
                            .fill(Color.red.opacity(selected ? 0.5 : 0.32))
                            .overlay(Rectangle().stroke(Color.red, lineWidth: selected ? 2 : 1))
                            .frame(width: max(2, scale.x(r.upperBound) - scale.x(r.lowerBound)), height: h)
                            .offset(x: scale.x(r.lowerBound))
                    }
                }
                if let draft {
                    Rectangle()
                        .fill(Color.red.opacity(0.3))
                        .frame(width: max(2, scale.x(draft.upperBound) - scale.x(draft.lowerBound)), height: h)
                        .offset(x: scale.x(draft.lowerBound))
                }
                if let selection {
                    selectionOverlay(selection.wrappedValue, scale: scale, height: h)
                }
                ForEach(Array(cuts.enumerated()), id: \.offset) { _, t in
                    Rectangle().fill(Color.white.opacity(0.8)).frame(width: 1.5, height: h).offset(x: scale.x(t) - 0.75)
                }
                if let markers {
                    ForEach(Array(markers.wrappedValue.enumerated()), id: \.offset) { _, t in
                        MarkerShape()
                            .fill(Color.yellow)
                            .frame(width: 11, height: h)
                            .offset(x: scale.x(t) - 5.5)
                    }
                }
                // Playhead.
                Rectangle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .frame(width: 2, height: h)
                    .offset(x: scale.x(session.currentTime) - 1)
                    .allowsHitTesting(false)
            }
            .frame(width: scale.width, height: h, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in changed(value, scale: scale) }
                .onEnded { value in ended(value, scale: scale) })
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
        .disabled(session.state != .ready)
    }

    @ViewBuilder
    private func strip(width: CGFloat, height: CGFloat) -> some View {
        if !session.thumbnails.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(session.thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(session.thumbnails.count), height: height)
                        .clipped()
                }
            }
            .frame(width: width, height: height)
            .background(Color.black)
        } else if let wave = session.waveform {
            Image(decorative: wave, scale: 1)
                .renderingMode(.template)
                .resizable()
                .foregroundStyle(Color.accentColor.opacity(0.85))
                .frame(width: width, height: height)
                .background(Color.primary.opacity(0.06))
        } else {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: width, height: height)
        }
    }

    private func selectionOverlay(_ r: ClosedRange<Double>, scale: TimelineScale, height: CGFloat) -> some View {
        let x0 = scale.x(r.lowerBound), x1 = scale.x(r.upperBound)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, x0), height: height)
            Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, scale.width - x1), height: height).offset(x: x1)
            Rectangle()
                .stroke(Color.yellow, lineWidth: 3)
                .frame(width: max(2, x1 - x0), height: height)
                .offset(x: x0)
            HandleShape(leading: true).fill(Color.yellow).frame(width: 10, height: height).offset(x: x0 - 2)
            HandleShape(leading: false).fill(Color.yellow).frame(width: 10, height: height).offset(x: x1 - 8)
        }
        .allowsHitTesting(false)
    }

    // MARK: Gestures

    private func changed(_ value: DragGesture.Value, scale: TimelineScale) {
        let x = value.location.x
        if drag == nil { drag = startMode(at: value.startLocation.x, scale: scale) }
        switch drag {
        case .scrub:
            session.pause()
            session.seek(to: scale.t(x))
        case .inPoint:
            guard let selection else { return }
            let t = min(scale.t(x), selection.wrappedValue.upperBound - minimumLength)
            selection.wrappedValue = max(0, t)...selection.wrappedValue.upperBound
            session.seek(to: selection.wrappedValue.lowerBound)
        case .outPoint:
            guard let selection else { return }
            let t = max(scale.t(x), selection.wrappedValue.lowerBound + minimumLength)
            selection.wrappedValue = selection.wrappedValue.lowerBound...min(session.duration, t)
            session.seek(to: selection.wrappedValue.upperBound)
        case .marker(let index):
            guard let markers, markers.wrappedValue.indices.contains(index) else { return }
            markers.wrappedValue[index] = scale.t(x)
            session.seek(to: scale.t(x))
        case .newInterval(let start):
            let t = scale.t(x)
            draft = min(start, t)...max(start, t)
        case nil:
            break
        }
    }

    private func ended(_ value: DragGesture.Value, scale: TimelineScale) {
        defer {
            drag = nil
            draft = nil
        }
        let moved = abs(value.translation.width) > 3
        if case .newInterval = drag {
            if moved, let draft, draft.upperBound - draft.lowerBound > 0.05, let intervals {
                intervals.wrappedValue.append(draft)
                selectedInterval?.wrappedValue = intervals.wrappedValue.count - 1
            } else {
                // A click: select the interval under the pointer, and seek.
                let t = scale.t(value.location.x)
                selectedInterval?.wrappedValue = intervals?.wrappedValue.firstIndex { $0.contains(t) }
                session.pause()
                session.seek(to: t)
            }
        }
        if case .marker = drag, let markers { markers.wrappedValue.sort() }
    }

    private var minimumLength: Double { max(0.05, session.frameDuration) }

    private func startMode(at x: CGFloat, scale: TimelineScale) -> Drag {
        if let selection {
            let r = selection.wrappedValue
            let dIn = abs(x - scale.x(r.lowerBound)), dOut = abs(x - scale.x(r.upperBound))
            if min(dIn, dOut) < 10 { return dIn <= dOut ? .inPoint : .outPoint }
        }
        if let markers, let i = markers.wrappedValue.firstIndex(where: { abs(scale.x($0) - x) < 6 }) {
            return .marker(i)
        }
        if intervals != nil { return .newInterval(scale.t(x)) }
        return .scrub
    }
}

/// A marker: line with a small flag at the top.
struct MarkerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(CGRect(x: rect.midX - 1, y: 0, width: 2, height: rect.height))
        p.move(to: CGPoint(x: rect.minX, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: 0))
        p.addLine(to: CGPoint(x: rect.midX, y: 8))
        p.closeSubpath()
        return p
    }
}

/// The in/out grips of a selection.
struct HandleShape: Shape {
    let leading: Bool

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: 3)
    }
}
