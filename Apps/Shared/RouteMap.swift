import MapKit
import RunloopCore
import SwiftUI

let routePlanningStart = CLLocationCoordinate2D(latitude: 45.0609793, longitude: 7.6585835)

struct RequestLocationPermissionOnLaunch: ViewModifier {
    let ready: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var locationManager: CLLocationManager?

    func body(content: Content) -> some View {
        content.onChange(of: ready && scenePhase == .active, initial: true) { _, canRequest in
            guard canRequest, locationManager == nil else { return }
            let manager = CLLocationManager()
            locationManager = manager
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            }
        }
    }
}

func routeDistanceText(_ meters: Double) -> String {
    Measurement(value: meters / 1000, unit: UnitLength.kilometers)
        .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                numberFormatStyle: .number.precision(.fractionLength(0...2))))
}

func routeSummary(distance: Double, mode: RouteMode?) -> String {
    let distanceText = routeDistanceText(distance)
    guard let mode else { return distanceText }
    let kind = mode == .manual ? "Tratta" : "Ad anello"
    return "\(distanceText) · \(kind)"
}

extension RouteCoordinate {
    init(_ value: CLLocationCoordinate2D) {
        self.init(latitude: value.latitude, longitude: value.longitude)
    }

    var location: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

func routeMapRect(_ coordinates: [RouteCoordinate]) -> MKMapRect {
    let rect = MKPolyline(coordinates: coordinates.map(\.location), count: coordinates.count).boundingMapRect
    return rect.insetBy(dx: -max(240, rect.width * 0.15), dy: -max(240, rect.height * 0.15))
}

/// A route with two endpoints, or a circuit returning to its start.
struct RouteModeGlyph: View {
    let mode: RouteMode
    @ScaledMetric(relativeTo: .footnote) private var side: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            let scale = size.width / 20
            context.scaleBy(x: scale, y: scale)
            let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            if mode == .manual {
                var line = Path()
                line.move(to: CGPoint(x: 4, y: 15))
                line.addQuadCurve(to: CGPoint(x: 10, y: 10), control: CGPoint(x: 4, y: 9))
                line.addQuadCurve(to: CGPoint(x: 16, y: 5), control: CGPoint(x: 16, y: 11))
                context.stroke(line, with: .foreground, style: stroke)
                context.fill(Path(ellipseIn: CGRect(x: 1, y: 12, width: 6, height: 6)), with: .foreground)
                context.fill(Path(ellipseIn: CGRect(x: 13.5, y: 2.5, width: 5, height: 5)), with: .foreground)
            } else {
                // A short city block with a cut-in corner and one starting point.
                var block = Path()
                block.move(to: CGPoint(x: 4, y: 14))
                block.addLine(to: CGPoint(x: 4, y: 4))
                block.addLine(to: CGPoint(x: 11, y: 4))
                block.addLine(to: CGPoint(x: 11, y: 8))
                block.addLine(to: CGPoint(x: 17, y: 8))
                block.addLine(to: CGPoint(x: 17, y: 16))
                block.addLine(to: CGPoint(x: 9, y: 16))
                context.stroke(block, with: .foreground, style: stroke)
                context.fill(Path(ellipseIn: CGRect(x: 1.4, y: 12.8, width: 5.2, height: 5.2)), with: .foreground)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// Draw a single short ring at the actual insertion point. Map pans, undo and mode changes stay quiet.
struct RoutePlacementFeedback: ViewModifier {
    let points: [RouteCoordinate]
    let proxy: MapProxy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.runloopAccent) private var accent
    @State private var point: RouteCoordinate?
    @State private var started: Date?

    func body(content: Content) -> some View {
        content.overlay {
            if !reduceMotion, let point, let started {
                TimelineView(.animation) { tick in
                    if let position = proxy.convert(point.location, to: .local) {
                        let progress = min(1, max(0, tick.date.timeIntervalSince(started) / 0.34))
                        Circle().strokeBorder(accent, lineWidth: 2)
                            .frame(width: 9 + 26 * progress, height: 9 + 26 * progress)
                            .opacity(1 - progress)
                            .position(position)
                    }
                }
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .onChange(of: points) { old, new in
            if !reduceMotion, new.count == old.count + 1, new.dropLast() == old[...] {
                point = new.last
            } else if !reduceMotion, new.count == old.count, new.first != old.first, new.dropFirst() == old.dropFirst() {
                point = new.first
            } else {
                point = nil
            }
            started = point == nil ? nil : .now
        }
        .task(id: started) {
            guard started != nil else { return }
            try? await Task.sleep(for: .milliseconds(340))
            if !Task.isCancelled { started = nil }
        }
    }
}

struct RouteVariantLabel: View {
    @Environment(\.runloopAccent) private var accent
    let index: Int
    let distance: String
    let selected: Bool
    let fillsWidth: Bool
    let namespace: Namespace.ID

    private var minimumWidth: CGFloat {
        #if os(iOS)
        fillsWidth ? 44 : 104
        #else
        44
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((index + 1).formatted(.number.precision(.integerLength(2))))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(selected ? accent : RunloopStyle.muted)
            Text(distance).font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(selected ? RunloopStyle.text : RunloopStyle.muted)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minWidth: minimumWidth, maxWidth: fillsWidth ? .infinity : nil, minHeight: 52, alignment: .leading)
        .background(RunloopStyle.panel, in: .rect(cornerRadius: 7))
        .overlay(alignment: .bottom) {
            if selected {
                Capsule().fill(accent).frame(height: 3)
                    .matchedGeometryEffect(id: "variant", in: namespace)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(.rect)
    }
}

struct RouteMapPin: View {
    @Environment(\.runloopAccent) private var accent
    let index: Int

    var body: some View {
        let color = index == 0 ? accent : RunloopStyle.text
        VStack(spacing: 0) {
            Group {
                if index == 0 {
                    Image(systemName: "flag.fill").font(.system(size: 10, weight: .semibold))
                } else {
                    Text(index.formatted()).font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundStyle(RunloopStyle.canvas)
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, 2)
            .background(color, in: .rect(cornerRadius: RunloopStyle.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: RunloopStyle.controlRadius).strokeBorder(RunloopStyle.canvas, lineWidth: 1.5) }

            Rectangle().fill(color).frame(width: 2, height: 5)
        }
        .accessibilityLabel(index == 0 ? "Partenza" : "Tappa \(index)")
    }
}

struct RouteReveal: View {
    @Environment(\.runloopAccent) private var accent
    // Five equal phases in the prototype. The selected geometry is complete at 800 ms.
    static let duration: TimeInterval = 0.8

    private static let phaseCount = 5
    private static let delay: TimeInterval = 0.05
    private let coordinates: [RouteCoordinate]
    let startedAt: Date
    let proxy: MapProxy

    init(coordinates: [RouteCoordinate], startedAt: Date, proxy: MapProxy) {
        // Bound projection work on a long GPX route and preserve its endpoint.
        let step = max(1, (coordinates.count + 899) / 900)
        var sampled = stride(from: 0, to: coordinates.count, by: step).map { coordinates[$0] }
        if let last = coordinates.last, sampled.last != last { sampled.append(last) }
        self.coordinates = sampled
        self.startedAt = startedAt
        self.proxy = proxy
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            Canvas { context, _ in
                let points = coordinates.compactMap { proxy.convert($0.location, to: .local) }
                guard points.count > 1 else { return }
                let shortPath = points.count <= Self.phaseCount ? Path { $0.addLines(points) } : nil
                let elapsed = timeline.date.timeIntervalSince(startedAt)
                let phaseLength = Self.duration / Double(Self.phaseCount)
                for index in 0..<Self.phaseCount {
                    let time = elapsed - Double(index) * phaseLength - Self.delay
                    guard time > 0 else { break }
                    let progress = min(1, time / (phaseLength - Self.delay))
                    let first = index * (points.count - 1) / Self.phaseCount
                    let last = (index + 1) * (points.count - 1) / Self.phaseCount
                    let segment: Path
                    if let shortPath {
                        segment = shortPath.trimmedPath(from: CGFloat(index) / CGFloat(Self.phaseCount),
                                                        to: CGFloat(index + 1) / CGFloat(Self.phaseCount))
                    } else {
                        segment = Path { $0.addLines(Array(points[first...last])) }
                    }
                    // Each matching Figma segment fades into place over 110 ms.
                    var layer = context
                    layer.opacity = progress * (2 - progress)
                    layer.stroke(segment, with: .color(RunloopStyle.canvas), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    layer.stroke(segment, with: .color(accent), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                }
            }
            .clipped()
        }
    }
}
