import CoreText
import MapKit
import RunloopCore
import SwiftUI

enum RunloopAccent: String, CaseIterable, Sendable {
    case yellow, blue, red, green

    static let defaultChoice: Self = .yellow
    static let storageKey = "runloop.accent"
    static let contextKey = "runloopAccent"

    var title: LocalizedStringKey {
        switch self {
        case .yellow: "Giallo"
        case .blue: "Azzurro"
        case .red: "Rosso"
        case .green: "Verde"
        }
    }

    var color: Color {
        switch self {
        case .yellow: RunloopStyle.rgb(0xF7F348)
        case .blue: RunloopStyle.rgb(0x48BFF7)
        case .red: RunloopStyle.rgb(0xF74B40)
        case .green: RunloopStyle.rgb(0x76F748)
        }
    }
}

extension EnvironmentValues {
    @Entry var runloopAccent = RunloopAccent.defaultChoice.color
}

enum RunloopStyle {
    static let canvas = rgb(0x141610)
    static let panel = rgb(0x1C2019)
    static let raised = rgb(0x2B3127)
    static let border = rgb(0x3B4537)
    static let text = rgb(0xF3F2E8)
    static let muted = rgb(0xB0BBAA)
    static let branch = rgb(0xA8AAB5)
    static let paused = rgb(0xFFC480)
    static let danger = rgb(0xFF9D91)

    static let radius: CGFloat = 9
    static let controlRadius: CGFloat = 5

    static func rgb(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255)
    }
}

enum RunloopType {
    private static let displayName = "BarlowCondensed-Bold"
    private static let hasDisplayFont: Bool = {
        guard let url = Bundle.main.url(forResource: displayName, withExtension: "ttf") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static let screenTitle = display(size: 51, relativeTo: .largeTitle)
    static let sectionTitle = display(size: 26, relativeTo: .title2)
    static let metric = display(size: 37, relativeTo: .largeTitle).monospacedDigit()
    static let compactMetric = display(size: 25, relativeTo: .title3).monospacedDigit()
    static let readout = Font.system(.caption, design: .monospaced).weight(.medium)
    static let control = Font.footnote.weight(.semibold)

    static func display(size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        hasDisplayFont ? .custom(displayName, size: size, relativeTo: style) : .system(style, weight: .heavy)
    }
}

enum RunloopMotion {
    static let press = Animation.easeOut(duration: 0.14)
    static let selection = Animation.spring(response: 0.27, dampingFraction: 0.85)
    static let status = Animation.easeOut(duration: 0.20)
    static let editorLayout = Animation.easeInOut(duration: 0.22)
}

struct RunloopButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .primary
    var compact = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.runloopAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: RunloopStyle.radius)
        configuration.label
            .font(compact ? RunloopType.control : .subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? 36 : minimumHeight)
            .foregroundStyle(kind == .primary ? RunloopStyle.canvas : kind == .destructive ? RunloopStyle.danger : RunloopStyle.text)
            .background(kind == .primary ? accent : RunloopStyle.panel, in: shape)
            .overlay { if kind != .primary { shape.strokeBorder(RunloopStyle.border, lineWidth: 1) } }
            .frame(minWidth: compact ? 44 : nil, minHeight: compact ? 44 : nil)
            .contentShape(.rect)
            .opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.48)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .animation(reduceMotion ? nil : RunloopMotion.press, value: configuration.isPressed)
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
            .animation(reduceMotion ? nil : RunloopMotion.press, value: configuration.isPressed)
    }
}

struct RunloopTrace: View {
    @Environment(\.runloopAccent) private var accent
    let coordinates: [RouteCoordinate]
    var color: Color? = nil
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
                context.stroke(line, with: .color(color ?? accent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
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
