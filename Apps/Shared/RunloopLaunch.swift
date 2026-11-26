import SwiftUI

/// The system launch screen and the first SwiftUI frame share the same canvas.
struct RunloopLaunch: ViewModifier {
    let runs: RunCompanion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var fading = false

    func body(content: Content) -> some View {
        let checking = runs.launchPhase == .checking
        let introducing = runs.launchPhase == .introducing && !reduceMotion
        let covered = !runs.isPresented && (checking || introducing)
        content
            .accessibilityHidden(covered)
            .allowsHitTesting(!covered)
            .overlay {
                if covered {
                    ZStack {
                        RunloopStyle.canvas
                        if introducing { DoubleStepIntro() }
                    }
                    .ignoresSafeArea()
                    .opacity(fading ? 0 : 1)
                    .accessibilityHidden(true)
                }
            }
            .task(id: runs.launchPhase) {
                guard runs.launchPhase == .introducing else { return }
                if !reduceMotion && !runs.isPresented {
                    do {
                        try await Task.sleep(for: .milliseconds(220))
                        withAnimation(.easeOut(duration: 0.14)) { fading = true }
                        try await Task.sleep(for: .milliseconds(140))
                    } catch { return }
                }
                runs.finishLaunch()
            }
            .onChange(of: runs.isPresented) { _, presented in
                if presented { runs.finishLaunch() }
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced && runs.launchPhase == .introducing { runs.finishLaunch() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background && runs.launchPhase == .introducing { runs.finishLaunch() }
            }
    }
}

private struct DoubleStepIntro: View {
    @Environment(\.runloopAccent) private var accent
    @State private var aligned = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            #if os(watchOS)
            let side = min(size.width * 0.75, size.height * 0.78)
            #else
            let side = min(size.width * 0.635, size.height * 0.40, 300)
            #endif
            ZStack {
                ForEach(0..<2) { index in
                    DoubleStepStroke(second: index == 1)
                        .stroke(accent, style: StrokeStyle(lineWidth: side * 0.07, lineCap: .square, lineJoin: .round))
                        .opacity(aligned ? 1 : 0)
                        .offset(x: aligned ? 0 : -0.07 * side, y: aligned ? 0 : 0.05 * side)
                        .animation(.easeOut(duration: 0.18).delay(Double(index) * 0.04), value: aligned)
                }
            }
            .frame(width: side, height: side)
            .position(x: size.width / 2, y: size.height * 0.49)
            #if os(iOS)
            Text(verbatim: "RUNLOOP")
                .font(RunloopType.display(size: min(side * 0.195, 52), relativeTo: .largeTitle))
                .foregroundStyle(RunloopStyle.text)
                .position(x: size.width / 2, y: size.height * 0.65)
            #endif
        }
        .onAppear { aligned = true }
    }
}

private struct DoubleStepStroke: Shape {
    let second: Bool
    func path(in rect: CGRect) -> Path {
        let shift: CGFloat = second ? 28 : 0
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * (x + shift) / 100, y: rect.minY + rect.height * y / 100)
        }
        return Path { path in
            path.move(to: point(17, 70))
            path.addLine(to: point(37, 30))
            path.addLine(to: point(54, 30))
            path.addLine(to: point(34, 70))
        }
    }
}
