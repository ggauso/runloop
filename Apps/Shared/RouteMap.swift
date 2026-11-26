import MapKit
import RunloopCore
import SwiftUI

let routePlanningStart = CLLocationCoordinate2D(latitude: 45.0609793, longitude: 7.6585835)

struct RequestLocationPermissionOnLaunch: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var locationManager: CLLocationManager?

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active, locationManager == nil else { return }
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

    var body: some View {
        HStack(spacing: 5) {
            Text("\(index + 1)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .padding(3)
                .frame(minWidth: 17, minHeight: 17)
                .background(Circle().fill(selected ? accent : RunloopStyle.raised))
                .foregroundStyle(selected ? RunloopStyle.canvas : RunloopStyle.muted)
            Text(distance).foregroundStyle(selected ? RunloopStyle.text : RunloopStyle.muted)
        }
        .font(RunloopType.readout)
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .padding(.horizontal, 7)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
        .frame(minWidth: 44, minHeight: 44)
        .overlay(alignment: .bottom) {
            if selected {
                Capsule().fill(accent)
                    .frame(width: 22, height: 2)
                    .matchedGeometryEffect(id: "variant", in: namespace)
                    .padding(.bottom, 5)
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
    private static let routeDrawDuration = 0.82
    private static let routeDelay = 0.83
    private static let branchDrawDuration = 0.67
    private static let branchLeadIn = 0.14
    private static let branchStagger = 0.14
    private static let branchFadeStart = 1.10
    private static let branchFadeDuration = 1.02

    private let coordinates: [RouteCoordinate]
    private let alternatives: [[RouteCoordinate]]
    let startedAt: Date
    let proxy: MapProxy

    init(coordinates: [RouteCoordinate], alternatives: [[RouteCoordinate]], startedAt: Date, proxy: MapProxy) {
        self.coordinates = Self.sample(coordinates, limit: alternatives.isEmpty ? 900 : 600)
        let branchSampleLimit = min(190, 575 / max(1, alternatives.count))
        self.alternatives = alternatives.map { Self.sample($0, limit: branchSampleLimit) }
        self.startedAt = startedAt
        self.proxy = proxy
    }

    static func duration(alternativeCount: Int) -> TimeInterval {
        guard alternativeCount > 0 else { return routeDrawDuration + 0.03 }
        return branchStart(at: alternativeCount - 1) + branchFadeStart + branchFadeDuration + 0.03
    }

    private static func branchStart(at index: Int) -> TimeInterval {
        branchLeadIn + Double(index) * branchStagger
    }

    private static func sample(_ coordinates: [RouteCoordinate], limit: Int) -> [RouteCoordinate] {
        let step = max(1, (coordinates.count + limit - 1) / limit)
        var samples = stride(from: 0, to: coordinates.count, by: step).map { coordinates[$0] }
        if let last = coordinates.last, samples.last != last { samples.append(last) }
        return samples
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, _ in
                let elapsed = timeline.date.timeIntervalSince(startedAt)
                for (index, alternative) in alternatives.enumerated() {
                    let branchTime = elapsed - Self.branchStart(at: index)
                    let fade = min(1, max(0, (branchTime - Self.branchFadeStart) / Self.branchFadeDuration))
                    let opacity = 1 - fade * fade * (3 - 2 * fade)
                    let progress = branchTime / Self.branchDrawDuration
                    guard opacity > 0, let branch = trace(alternative, progress: progress) else { continue }
                    context.stroke(branch, with: .color(.black.opacity(0.78 * opacity)),
                                   style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round))
                    context.stroke(branch, with: .color(RunloopStyle.branch.opacity(0.94 * opacity)),
                                   style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                    drawHead(of: branch, progress: progress, radius: 2.5, in: context)
                }

                let delay = alternatives.isEmpty ? 0 : Self.routeDelay
                let progress = (elapsed - delay) / Self.routeDrawDuration
                guard let stroke = trace(coordinates, progress: progress) else { return }
                context.stroke(stroke, with: .color(.black.opacity(0.92)),
                               style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                context.stroke(stroke, with: .color(accent),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                drawHead(of: stroke, progress: progress, radius: 3, in: context)
            }
            .clipped()
        }
    }

    private func drawHead(of stroke: Path, progress: Double, radius: CGFloat, in context: GraphicsContext) {
        guard progress < 1, let head = stroke.currentPoint else { return }
        let marker = Path(ellipseIn: CGRect(x: head.x - radius, y: head.y - radius, width: radius * 2, height: radius * 2))
        context.fill(marker, with: .color(RunloopStyle.text.opacity(min(1, (1 - progress) * 12))))
    }

    private func trace(_ coordinates: [RouteCoordinate], progress: Double) -> Path? {
        guard progress > 0 else { return nil }
        let points = coordinates.compactMap { proxy.convert($0.location, to: .local) }
        guard points.count > 1 else { return nil }
        let path = Path { $0.addLines(points) }
        let t = min(1, progress)
        return t == 1 ? path : path.trimmedPath(from: 0, to: t * (2 - t))
    }
}
