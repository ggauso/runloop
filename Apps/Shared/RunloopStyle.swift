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

    static let screenTitle = display(size: 49, relativeTo: .largeTitle)
    static let sectionTitle = display(size: 26, relativeTo: .title2)
    static let metric = display(size: 37, relativeTo: .largeTitle).monospacedDigit()
    static let compactMetric = display(size: 25, relativeTo: .title3).monospacedDigit()
    static let readout = Font.system(.caption, design: .monospaced).weight(.medium)
    #if os(watchOS)
    static let control = Font.caption2.weight(.semibold)
    #else
    static let control = Font.footnote.weight(.semibold)
    #endif

    static func display(size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        hasDisplayFont ? .custom(displayName, size: size, relativeTo: style) : .system(style, weight: .heavy)
    }
}

enum RunloopMotion {
    static let press = Animation.easeOut(duration: 0.14)
    static let selection = Animation.easeOut(duration: 0.22)
    static let status = Animation.easeOut(duration: 0.20)
    static let editorLayout = selection
}

struct RunloopHeading: View {
    let context: String
    let title: String
    @Environment(\.runloopAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(context.uppercased()).font(RunloopType.readout)
                    .foregroundStyle(RunloopStyle.muted)
                Spacer()
                Canvas { graphics, size in
                    var mark = Path()
                    for offset in [0.0, 10.0] {
                        mark.move(to: CGPoint(x: 3 + offset, y: 18))
                        mark.addLine(to: CGPoint(x: 10 + offset, y: 4))
                        mark.addLine(to: CGPoint(x: 16 + offset, y: 4))
                        mark.addLine(to: CGPoint(x: 9 + offset, y: 18))
                    }
                    graphics.stroke(mark, with: .color(accent), lineWidth: 2.5)
                }.frame(width: 29, height: 23).accessibilityHidden(true)
            }
            Text(title).font(RunloopType.screenTitle).accessibilityAddTraits(.isHeader)
        }
    }
}

private struct RunloopActionLabel: LabelStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        #if os(watchOS)
        ViewThatFits(in: .horizontal) {
            row(configuration)
            configuration.title
        }
        #else
        row(configuration)
        #endif
    }

    private func row(_ configuration: Configuration) -> some View {
        HStack(spacing: compact ? 4 : 10) {
            if compact { configuration.icon }
            #if os(watchOS)
            configuration.title.fixedSize(horizontal: true, vertical: false)
            #else
            configuration.title
            #endif
            if !compact {
                Spacer(minLength: 5)
                configuration.icon
            }
        }
    }
}

struct RunloopButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .primary
    var compact = false
    var fillsAvailableWidth = false
    #if os(watchOS)
    @ScaledMetric(relativeTo: .caption2) private var compactSize: CGFloat = 12
    #endif
    @Environment(\.isEnabled) private var enabled
    @Environment(\.runloopAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: RunloopStyle.radius)
        configuration.label
            .labelStyle(RunloopActionLabel(compact: compact))
            #if os(watchOS)
            .font(compact ? .system(size: compactSize, weight: .semibold) : .subheadline.weight(.semibold))
            #else
            .font(compact ? RunloopType.control : .subheadline.weight(.semibold))
            #endif
            .multilineTextAlignment(.leading)
            .padding(.horizontal, compact ? 7 : 16)
            .padding(.vertical, 8)
            .frame(maxWidth: compact && !fillsAvailableWidth ? nil : .infinity, minHeight: compact ? 36 : minimumHeight, alignment: compact ? .center : .leading)
            .foregroundStyle(kind == .primary ? RunloopStyle.canvas : kind == .destructive ? RunloopStyle.danger : RunloopStyle.text)
            .background(kind == .primary ? accent : kind == .destructive ? RunloopStyle.panel : RunloopStyle.raised, in: shape)
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
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
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
