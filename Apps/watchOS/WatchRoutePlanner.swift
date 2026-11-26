import CoreLocation
import MapKit
import RunloopCore
import SwiftUI

struct WatchRoutePlanner: View {
    @Environment(\.runloopAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Namespace private var editorSelection

    let inbox: WatchRouteInbox
    private let source: RouteTransfer?

    @State private var mode = RouteMode.roundTrip
    @State private var target = 5000
    @State private var waypoints: [RouteCoordinate] = []
    @State private var camera: MapCameraPosition = .region(region(around: routePlanningStart))
    @State private var center = routePlanningStart
    @State private var location = WatchPlannerLocation()
    @State private var previews: [RoutePreview] = []
    @State private var chosen = 0
    @State private var previewMode: RouteMode?
    @State private var originalPreviewID: UUID?
    @State private var revealedAt: Date?
    @State private var branchCount = 0
    @State private var search = LoopSearch()
    @State private var operation: Task<Void, Never>?
    @State private var message: String?
    @State private var showsSave = false
    @State private var name = ""

    init(inbox: WatchRouteInbox, source: RouteTransfer? = nil) {
        self.inbox = inbox
        self.source = source
        guard let source, let start = source.geometry.coordinates.first else { return }
        let existingMode = source.mode ?? (start == source.geometry.coordinates.last ? .roundTrip : .manual)
        let preview = RoutePreview(coordinates: source.geometry.coordinates, distanceMeters: source.distanceMeters,
                                   provider: source.provider)
        _waypoints = State(initialValue: source.waypoints ?? [start])
        _mode = State(initialValue: existingMode == .roundTrip ? .roundTrip : .manual)
        _target = State(initialValue: source.targetDistanceMeters ?? 5000)
        _camera = State(initialValue: .rect(routeMapRect(preview.coordinates)))
        _center = State(initialValue: start.location)
        _previews = State(initialValue: [preview])
        _previewMode = State(initialValue: existingMode)
        _originalPreviewID = State(initialValue: preview.id)
        _search = State(initialValue: LoopSearch(existing: existingMode == .manual ? nil : preview))
    }

    private var preview: RoutePreview? { previews.indices.contains(chosen) ? previews[chosen] : nil }
    private var loopMode: RouteMode { mode == .roundTrip ? .roundTrip : .waypointLoop }
    private var visibleWaypoints: [RouteCoordinate] { mode == .roundTrip ? Array(waypoints.prefix(1)) : waypoints }
    private var busy: Bool { operation != nil }
    private var canCalculate: Bool { draft(loopMode).isValid && inbox.currentOwner != nil }

    var body: some View {
        ScrollViewReader { scroll in
            content
                .onChange(of: previews.first?.id) { _, id in
                    guard let id, id != originalPreviewID else { return }
                    withAnimation(reduceMotion ? nil : RunloopMotion.editorLayout) {
                        scroll.scrollTo("routeMap", anchor: .top)
                    }
                }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                modePicker
                map.id("routeMap")
                pointControls

                if mode == .roundTrip { distanceTarget }

                if let preview {
                    Text(routeDistanceText(preview.distanceMeters))
                        .font(RunloopType.compactMetric)
                        .accessibilityIdentifier("watch.route.distance")
                    if previews.count > 1 { variants }
                    if preview.provider == "graphhopper" {
                        Text("© OpenStreetMap contributors").font(.caption2).foregroundStyle(RunloopStyle.muted)
                    }
                }

                if let status = message ?? location.message {
                    Text(status).font(.footnote).foregroundStyle(RunloopStyle.danger)
                        .accessibilityIdentifier("watch.route.message")
                } else if inbox.currentOwner == nil {
                    Text("Accedi a Runloop su iPhone per creare percorsi.")
                        .font(.footnote).foregroundStyle(RunloopStyle.muted)
                }

                actions
            }
            .padding(.horizontal, 6)
        }
        .runloopCanvas()
        .navigationTitle(source == nil ? "Nuovo percorso" : "Crea variante")
        .onChange(of: target) { resetResults() }
        .onChange(of: location.fix) { _, fix in
            guard let fix, !busy else { return }
            setStart(fix)
            camera = .region(Self.region(around: fix.location))
        }
        .onChange(of: inbox.currentOwner) { resetResults(); dismiss() }
        .onDisappear { operation?.cancel(); operation = nil; location.cancel() }
        .task(id: revealedAt) {
            guard let revealedAt else { return }
            try? await Task.sleep(for: .seconds(RouteReveal.duration(alternativeCount: branchCount)))
            if !Task.isCancelled, self.revealedAt == revealedAt { self.revealedAt = nil }
        }
        .sensoryFeedback(.selection, trigger: waypoints)
        .sensoryFeedback(.selection, trigger: mode)
        .sensoryFeedback(.selection, trigger: preview?.id) { _, current in current != nil }
        .alert("Salva percorso", isPresented: $showsSave) {
            TextField("Nome", text: $name)
            Button("Annulla", role: .cancel) {}
            Button("Salva", action: save)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            modeButton("Manuale", value: .manual)
            modeButton("Ad anello", value: .roundTrip)
        }
        .runloopPanel()
        .disabled(busy)
    }

    private func modeButton(_ title: String, value: RouteMode) -> some View {
        Button {
            guard mode != value else { return }
            withAnimation(reduceMotion ? nil : RunloopMotion.editorLayout) {
                mode = value
                resetResults()
            }
        } label: {
            HStack(spacing: 3) {
                if !dynamicTypeSize.isAccessibilitySize { RouteModeGlyph(mode: value) }
                Text(title)
            }
                .font(RunloopType.control)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(mode == value ? accent : RunloopStyle.muted)
                .background {
                    if mode == value {
                        RoundedRectangle(cornerRadius: RunloopStyle.controlRadius)
                            .fill(RunloopStyle.raised)
                            .matchedGeometryEffect(id: "mode", in: editorSelection)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
        .accessibilityIdentifier(value == .manual ? "watch.route.manual" : "watch.route.loop")
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                if let preview {
                    let isRevealing = revealedAt != nil && !reduceMotion
                    MapPolyline(coordinates: preview.coordinates.map(\.location))
                        .stroke(.black.opacity(isRevealing ? 0 : 0.8), lineWidth: 7)
                    MapPolyline(coordinates: preview.coordinates.map(\.location))
                        .stroke(accent.opacity(isRevealing ? 0 : 1), lineWidth: 3)
                }
                ForEach(Array(visibleWaypoints.enumerated()), id: \.offset) { index, point in
                    Annotation(index == 0 ? "Partenza" : "Tappa \(index)", coordinate: point.location, anchor: .bottom) {
                        RouteMapPin(index: index)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(emphasis: .muted))
            .modifier(RoutePlacementFeedback(points: waypoints, proxy: proxy))
            .onMapCameraChange { center = $0.camera.centerCoordinate }
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                if let point = proxy.convert(tap.location, from: .local) { select(point) }
            })
            .overlay {
                if !reduceMotion, let revealedAt, let preview {
                    let branches = branchCount == 0 ? [] : previews.indices.filter { $0 != chosen }.map { previews[$0].coordinates }
                    RouteReveal(coordinates: preview.coordinates, alternatives: branches, startedAt: revealedAt, proxy: proxy)
                        .accessibilityHidden(true).allowsHitTesting(false)
                } else if preview == nil {
                    Image(systemName: "plus")
                        .font(.footnote.weight(.bold)).foregroundStyle(RunloopStyle.text)
                        .shadow(color: .black, radius: 2).accessibilityHidden(true).allowsHitTesting(false)
                }
            }
        }
        .frame(height: 104)
        .clipShape(.rect(cornerRadius: RunloopStyle.radius))
        .accessibilityIdentifier("watch.route.map")
    }

    private var pointControls: some View {
        HStack(spacing: 4) {
            let addingStop = mode == .manual && !waypoints.isEmpty
            Button(addingStop ? "Tappa" : "Centro mappa",
                   systemImage: "plus") { select(center) }
                .buttonStyle(RunloopButtonStyle(kind: .secondary, compact: true))
                .accessibilityLabel(addingStop ? "Aggiungi tappa al centro della mappa" : "Usa il centro della mappa")
                .accessibilityIdentifier("watch.route.center")
            Button("La mia posizione", systemImage: "location") {
                message = nil
                location.request()
            }
                .labelStyle(.iconOnly)
                .buttonStyle(RunloopButtonStyle(kind: .secondary, compact: true))
                .disabled(location.isLocating)
                .accessibilityIdentifier("watch.route.location")
            if mode == .manual && !waypoints.isEmpty {
                Button("Rimuovi ultimo punto", systemImage: "arrow.uturn.backward") {
                    waypoints.removeLast()
                    resetResults()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(RunloopButtonStyle(kind: .secondary, compact: true))
                .accessibilityIdentifier("watch.route.undo")
            }
        }
        .disabled(busy)
    }

    private var distanceTarget: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Obiettivo").font(.caption2).foregroundStyle(RunloopStyle.muted)
                Text(routeDistanceText(Double(target))).font(RunloopType.readout)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : RunloopMotion.status, value: target)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button("Riduci obiettivo", systemImage: "minus") { target -= 1000 }
                .labelStyle(.iconOnly)
                .buttonStyle(RunloopButtonStyle(kind: .secondary, compact: true))
                .disabled(target <= 1000)
            Button("Aumenta obiettivo", systemImage: "plus") { target += 1000 }
                .labelStyle(.iconOnly)
                .buttonStyle(RunloopButtonStyle(kind: .secondary, compact: true))
                .disabled(target >= 50000)
        }
        .disabled(busy)
    }

    private var variants: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(Array(previews.enumerated()), id: \.element.id) { index, option in
                    Button {
                        guard index != chosen else { return }
                        withAnimation(reduceMotion ? nil : RunloopMotion.status) { chosen = index }
                        reveal(branches: false)
                    } label: {
                        RouteVariantLabel(index: index, distance: routeDistanceText(option.distanceMeters),
                                          selected: index == chosen, fillsWidth: false, namespace: editorSelection)
                    }
                    .buttonStyle(RunloopPressStyle())
                    .accessibilityLabel("Variante \(index + 1), \(routeDistanceText(option.distanceMeters))")
                    .accessibilityAddTraits(index == chosen ? .isSelected : [])
                    .accessibilityIdentifier("watch.route.alternative.\(index + 1)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .disabled(busy)
    }

    @ViewBuilder private var actions: some View {
        if busy {
            ProgressView("Attendi…")
        } else {
            if mode == .manual && previewMode != .manual {
                Button("Calcola tratta", systemImage: "arrow.right") { calculate(.manual) }
                    .buttonStyle(RunloopButtonStyle(kind: .secondary))
                    .disabled(!canCalculate)
                    .accessibilityIdentifier("watch.route.calculate")
            }
            Button(previewMode == loopMode ? "Altri anelli" : "Genera anelli", systemImage: "arrow.clockwise") {
                calculate(loopMode)
            }
            .buttonStyle(RunloopButtonStyle(kind: preview == nil ? .primary : .secondary))
            .disabled(!canCalculate)
            .accessibilityIdentifier("watch.route.generate")
            if let preview, preview.id != originalPreviewID {
                Button("Salva percorso", systemImage: "checkmark") {
                    if name.isEmpty {
                        name = mode == .roundTrip ? "Anello di \(routeDistanceText(preview.distanceMeters))"
                            : "Percorso di \(routeDistanceText(preview.distanceMeters))"
                    }
                    showsSave = true
                }
                .buttonStyle(RunloopButtonStyle())
                .accessibilityIdentifier("watch.route.save")
            }
        }
    }

    private func draft(_ calculation: RouteMode) -> RouteDraft {
        RouteDraft(mode: calculation, waypoints: visibleWaypoints, targetDistanceMeters: target)
    }

    private func select(_ point: CLLocationCoordinate2D) {
        let coordinate = RouteCoordinate(point)
        guard !busy, coordinate.isValid else { return }
        if mode == .roundTrip {
            location.cancel()
            setStart(coordinate)
        } else if waypoints.last != coordinate, waypoints.count < RouteDraft.maximumWaypoints {
            location.cancel()
            waypoints.append(coordinate)
            resetResults()
        }
    }

    private func setStart(_ point: RouteCoordinate) {
        if waypoints.isEmpty { waypoints = [point] }
        else { waypoints[0] = point }
        resetResults()
    }

    private func resetResults() {
        previews = []
        previewMode = nil
        chosen = 0
        revealedAt = nil
        message = nil
        search = LoopSearch()
    }

    private func calculate(_ calculation: RouteMode) {
        guard !busy, canCalculate, let start = waypoints.first else { return }
        let draft = draft(calculation)
        let seeds = calculation == .manual ? [] : search.reserveSeeds()
        let previous = previewMode == calculation ? preview : nil
        message = nil
        operation = Task {
            defer { operation = nil }
            do {
                let reply = try await inbox.planRoute(draft, action: .calculate(seeds: seeds))
                guard !Task.isCancelled, case .previews(let candidates) = reply else { return }
                let results = calculation == .manual ? candidates : search.rank(candidates, previous: previous,
                    reference: calculation == .waypointLoop ? draft.waypoints.last ?? start : start,
                    targetDistance: calculation == .roundTrip ? Double(draft.targetDistanceMeters) : nil)
                guard !results.isEmpty else {
                    message = "Nessun altro anello trovato. Riprova o sposta un punto."
                    return
                }
                chosen = 0
                previews = results
                previewMode = calculation
                reveal(branches: true)
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }

    private func reveal(branches: Bool) {
        guard let preview else { return }
        let alternatives = branches && !reduceMotion ? previews.indices.filter { $0 != chosen }.map { previews[$0] } : []
        branchCount = alternatives.count
        camera = .rect(routeMapRect(preview.coordinates + alternatives.flatMap(\.coordinates)))
        revealedAt = reduceMotion ? nil : .now
    }

    private func save() {
        guard !busy, let preview, let previewMode else { return }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(title.count) else {
            message = "Inserisci un nome da 1 a 80 caratteri."
            return
        }
        message = nil
        operation = Task {
            defer { operation = nil }
            do {
                let reply = try await inbox.planRoute(draft(previewMode), action: .save(id: preview.id, name: title, preview: preview))
                guard !Task.isCancelled, case .saved = reply else { return }
                dismiss()
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }

    private static func region(around coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, latitudinalMeters: 2800, longitudinalMeters: 2800)
    }
}

@MainActor
@Observable
private final class WatchPlannerLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var requested = false
    private(set) var fix: RouteCoordinate?
    private(set) var message: String?
    private(set) var isLocating = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func request() {
        isLocating = true
        message = nil
        fix = nil
        locationManagerDidChangeAuthorization(manager)
    }

    func cancel() {
        message = nil
        requested = false
        isLocating = false
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isLocating, !requested else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            requested = true
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied:
            cancel()
            message = "Scegli un punto sulla mappa o attiva la posizione nelle Impostazioni del Watch."
        default:
            cancel()
            message = "Posizione non disponibile. Scegli un punto sulla mappa."
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isLocating else { return }
        guard let location = locations.last, location.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(location.coordinate) else {
            self.locationManager(manager, didFailWithError: CLError(.locationUnknown))
            return
        }
        cancel()
        fix = RouteCoordinate(location.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        guard isLocating else { return }
        cancel()
        message = "Posizione non disponibile. Scegli un punto sulla mappa."
    }
}
