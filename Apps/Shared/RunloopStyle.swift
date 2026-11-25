import MapKit
import RunloopCore
import SwiftUI

enum RunloopStyle {
    static let canvas = Color(red: 16 / 255, green: 17 / 255, blue: 20 / 255)
    static let panel = Color(red: 26 / 255, green: 28 / 255, blue: 33 / 255)
    static let border = Color(red: 60 / 255, green: 64 / 255, blue: 73 / 255)
    static let text = Color(red: 245 / 255, green: 246 / 255, blue: 240 / 255)
    static let muted = Color(red: 175 / 255, green: 181 / 255, blue: 191 / 255)
    static let accent = Color(red: 217 / 255, green: 255 / 255, blue: 74 / 255)
    static let danger = Color(red: 255 / 255, green: 154 / 255, blue: 147 / 255)

    static let radius: CGFloat = 16
}

struct RunloopButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .primary
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: RunloopStyle.radius)
        configuration.label
            .font(.subheadline.weight(.heavy))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .foregroundStyle(kind == .primary ? RunloopStyle.canvas : kind == .destructive ? RunloopStyle.danger : RunloopStyle.text)
            .background(kind == .primary ? RunloopStyle.accent : RunloopStyle.panel, in: shape)
            .overlay { if kind != .primary { shape.strokeBorder(RunloopStyle.border, lineWidth: 1) } }
            .contentShape(shape)
            .opacity(enabled ? (configuration.isPressed ? 0.76 : 1) : 0.48)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.977 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }

    private var minimumHeight: CGFloat {
        #if os(watchOS)
        44
        #else
        52
        #endif
    }
}

struct RunloopPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.74 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct RunloopTrace: View {
    let coordinates: [RouteCoordinate]
    var color = RunloopStyle.accent
    var showsGrid = false
    var lineWidth: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            if showsGrid {
                var grid = Path()
                for x in stride(from: CGFloat(0), to: size.width, by: 16) {
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: CGFloat(0), to: size.height, by: 16) {
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(RunloopStyle.border.opacity(0.55)), lineWidth: 0.5)
            }

            let points = projected(in: size)
            guard let start = points.first else { return }
            if points.count > 1 {
                var line = Path()
                line.addLines(points)
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
            let marker = max(3, lineWidth * 2)
            let dot = Path(ellipseIn: CGRect(x: start.x - marker / 2, y: start.y - marker / 2, width: marker, height: marker))
            context.fill(dot, with: .color(RunloopStyle.text))
        }
        .accessibilityHidden(true)
    }

    private func projected(in size: CGSize) -> [CGPoint] {
        let points = coordinates.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        guard let start = points.first else { return [] }
        let world = MKMapSize.world.width
        let unwrapped = points.map { point in
            var x = point.x - start.x
            if x > world / 2 { x -= world }
            if x < -world / 2 { x += world }
            return CGPoint(x: x, y: point.y - start.y)
        }
        let minX = unwrapped.map(\.x).min() ?? 0
        let minY = unwrapped.map(\.y).min() ?? 0
        let width = (unwrapped.map(\.x).max() ?? 0) - minX
        let height = (unwrapped.map(\.y).max() ?? 0) - minY
        let inset = max(lineWidth * 3, 7)
        let scale = min(max(1, size.width - 2 * inset) / max(1, width), max(1, size.height - 2 * inset) / max(1, height))
        let origin = CGPoint(x: (size.width - width * scale) / 2, y: (size.height - height * scale) / 2)
        return unwrapped.map { CGPoint(x: origin.x + ($0.x - minX) * scale, y: origin.y + ($0.y - minY) * scale) }
    }
}

extension View {
    func runloopPanel() -> some View {
        background(RunloopStyle.panel, in: RoundedRectangle(cornerRadius: RunloopStyle.radius))
            .overlay {
                RoundedRectangle(cornerRadius: RunloopStyle.radius)
                    .strokeBorder(RunloopStyle.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    func runloopCanvas() -> some View {
        background(RunloopStyle.canvas.ignoresSafeArea())
            .foregroundStyle(RunloopStyle.text)
    }
}
