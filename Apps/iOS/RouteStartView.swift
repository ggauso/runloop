import CoreLocation
import MapKit
import RunloopCore
import SwiftUI

struct RouteStartView: View {
    private static let loopCandidateCount = 4

    @Environment(AccountAccess.self) private var access
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var controlFontSize = 13.0
    private let existing: SavedRoute?
    private let onSave: (SavedRoute) -> Void
    @State private var selection = RouteStartSelection()
    @State private var mode = RouteMode.manual
    @State private var targetMeters = 5000
    @State private var previews: [RoutePreview] = []
    @State private var chosenPreview = 0
    @State private var previewMode: RouteMode?
    @State private var seenLoops: Set<Int> = []
    @State private var usedSeeds: Set<Int> = []
    @State private var revealStartedAt: Date?
    @State private var routingMessage: String?
    @State private var routeTask: Task<Void, Never>?
    @State private var isCalculating = false
    @State private var showsWaypoints = false
    @State private var draftID = UUID()
    @State private var name = ""
    @State private var showsSave = false
    @State private var isSaving = false
    @State private var saveMessage: String?

    init(existing: SavedRoute? = nil, onSave: @escaping (SavedRoute) -> Void) {
        self.existing = existing
        self.onSave = onSave
        if let existing {
            _selection = State(initialValue: RouteStartSelection(points: existing.waypoints, geometry: existing.geometry.coordinates))
            _mode = State(initialValue: existing.mode == .roundTrip ? .roundTrip : .manual)
            _targetMeters = State(initialValue: existing.targetDistanceMeters ?? 5000)
            _previews = State(initialValue: [existing.preview])
            _previewMode = State(initialValue: existing.mode)
            if existing.mode != .manual {
                _seenLoops = State(initialValue: [existing.preview.directionIndependentHash])
            }
            _name = State(initialValue: existing.name)
        }
    }

    private var preview: RoutePreview? { previews.indices.contains(chosenPreview) ? previews[chosenPreview] : nil }
    private var isRevealing: Bool { revealStartedAt != nil && !reduceMotion }
    private var revealAlternatives: [[RouteCoordinate]] {
        previews.indices.filter { $0 != chosenPreview }.map { previews[$0].coordinates }
    }
    private var visiblePoints: [RouteCoordinate] { mode == .manual ? selection.points : Array(selection.points.prefix(1)) }
    private var canCalculate: Bool { selection.points.count >= (mode == .manual ? 2 : 1) }

    var body: some View {
        if let existing, existing.ownerID != access.session?.user.id {
            ContentUnavailableView("Percorso non disponibile", systemImage: "map")
        } else {
            editor
        }
    }

    private var editor: some View {
        @Bindable var selection = selection
        return MapReader { proxy in
            Map(position: $selection.camera) {
                if let preview {
                    MapPolyline(coordinates: preview.coordinates.map(\.location))
                        .stroke(.black.opacity(isRevealing ? 0 : 0.85), lineWidth: 8)
                    MapPolyline(coordinates: preview.coordinates.map(\.location))
                        .stroke(RunloopStyle.accent.opacity(isRevealing ? 0 : 1), lineWidth: 4)
                }
                ForEach(Array(visiblePoints.enumerated()), id: \.offset) { index, point in
                    Marker(index == 0 ? "Partenza" : "Tappa \(index)",
                           systemImage: index == 0 ? "flag.fill" : "circle.fill", coordinate: point.location)
                        .tint(index == 0 ? RunloopStyle.accent : RunloopStyle.muted)
                }
            }
            .mapStyle(.standard(emphasis: .muted))
            .onTapGesture { point in
                if let coordinate = proxy.convert(point, from: .local) {
                    selection.select(coordinate, replacingStart: mode == .roundTrip)
                }
            }
            .onMapCameraChange { context in
                selection.center = context.camera.centerCoordinate
            }
            .mapControls { MapCompass() }
            .overlay {
                if let started = revealStartedAt, isRevealing, let preview {
                    RouteReveal(coordinates: preview.coordinates, alternatives: revealAlternatives,
                                startedAt: started, proxy: proxy)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controls
        }
        .navigationTitle(existing == nil ? "Nuovo percorso" : "Modifica percorso")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selection.points) { invalidatePreview() }
        .onChange(of: access.session?.user.id) { invalidatePreview() }
        .onChange(of: mode) { invalidatePreview() }
        .onChange(of: targetMeters) { if mode == .roundTrip { invalidatePreview() } }
        .task(id: revealStartedAt) {
            guard let started = revealStartedAt else { return }
            try? await Task.sleep(for: .seconds(RouteReveal.duration(alternativeCount: revealAlternatives.count)))
            if !Task.isCancelled, revealStartedAt == started { revealStartedAt = nil }
        }
        .onDisappear {
            routeTask?.cancel()
            routeTask = nil
            isCalculating = false
            revealStartedAt = nil
        }
        .sensoryFeedback(.selection, trigger: mode)
        .sensoryFeedback(.selection, trigger: visiblePoints.count)
        .sensoryFeedback(.selection, trigger: chosenPreview)
        .sheet(isPresented: $showsWaypoints) { waypointList }
        .alert("Salva percorso", isPresented: $showsSave) {
            TextField("Nome del percorso", text: $name)
            Button("Annulla", role: .cancel) {}
            Button("Salva") { Task { await save() } }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 5) {
            if isSaving {
                ProgressView("Salvataggio…")
            } else if let saveMessage {
                Text(saveMessage).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                modeButton("Manuale", value: .manual, icon: "point.topleft.down.to.point.bottomright.curvepath")
                modeButton("Ad anello", value: .roundTrip, icon: "arrow.trianglehead.clockwise")
            }
            .padding(.horizontal, 3)
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(RunloopStyle.panel)
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(RunloopStyle.border) }
                    .frame(height: 34)
                    .allowsHitTesting(false)
            }
            .accessibilityIdentifier("route.mode")

            HStack {
                Text(selection.points.isEmpty ? "Scegli la partenza" : "Partenza selezionata")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("route.startStatus")
                Spacer(minLength: 8)
                if !selection.points.isEmpty {
                    if mode == .manual {
                        if canCalculate {
                            Menu("Opzioni dei punti", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                                Button("Punti (\(selection.points.count))", systemImage: "list.bullet") { showsWaypoints = true }
                                if previewMode == .waypointLoop, !isCalculating, !isSaving {
                                    Button("Calcola tratta", systemImage: "arrow.forward") { calculate(.manual) }
                                }
                            }
                            .labelStyle(.iconOnly)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 5)
                            .accessibilityIdentifier("route.editPoints")
                        }
                        Button("Annulla ultimo punto", systemImage: "arrow.uturn.backward") { selection.undo() }
                            .labelStyle(.iconOnly)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 5)
                            .accessibilityIdentifier("route.undoPoint")
                    }
                    Button("Centra sulla partenza", systemImage: "scope") { selection.recenter() }
                        .labelStyle(.iconOnly)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 5)
                        .accessibilityIdentifier("route.recenter")
                }
            }

            if selection.isLocating {
                ProgressView("Ricerca della posizione…")
            } else if let message = selection.locationMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("route.locationStatus")
            } else if selection.points.isEmpty {
                Text("Tocca la mappa o usa il centro.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let routingMessage {
                Text(routingMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("route.routingStatus")
            } else if let preview {
                HStack(alignment: .firstTextBaseline) {
                    Text(routeDistanceText(preview.distanceMeters))
                        .font(.title3.weight(.bold)).monospacedDigit()
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("route.distance")
                    Spacer(minLength: 8)
                    Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.caption2).foregroundStyle(RunloopStyle.muted)
                }
            } else if mode == .manual && selection.points.count == 1 {
                Text("Aggiungi una tappa toccando la mappa.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if mode == .roundTrip {
                Stepper(value: $targetMeters, in: 500...50000, step: 500) {
                    Text("Obiettivo: \(routeDistanceText(Double(targetMeters)))")
                }
                .accessibilityIdentifier("route.targetDistance")

            }

            if previews.count > 1 {
                Picker("Alternativa", selection: Binding(get: { chosenPreview }, set: { index in
                    guard previews.indices.contains(index), index != chosenPreview else { return }
                    chosenPreview = index
                    present(previews[index])
                })) {
                    ForEach(Array(previews.enumerated()), id: \.offset) { index, option in
                        Text("\(index + 1) · \(routeDistanceText(option.distanceMeters))").tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("route.alternatives")
            }

            HStack(spacing: 8) { selectionButtons }

            if canCalculate {
                routeActions
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RunloopStyle.canvas)
        .overlay(alignment: .top) { Divider().overlay(RunloopStyle.border) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: chosenPreview)
    }

    private var routeActions: some View {
        HStack(spacing: 8) {
            if isCalculating {
                ProgressView("Calcolo percorso…").font(.footnote)
            } else if access.session == nil || access.client == nil {
                NavigationLink("Accedi per calcolare") { AccountView() }
            } else {
                let loopMode: RouteMode = mode == .manual ? .waypointLoop : .roundTrip
                if mode == .manual && preview == nil {
                    Button("Calcola tratta", systemImage: "arrow.forward") { calculate(.manual) }
                        .buttonStyle(RouteEditorActionStyle(fontSize: controlFontSize))
                        .accessibilityIdentifier("route.calculate")
                }
                Button(previewMode == loopMode ? "Altri anelli" : mode == .manual ? "Genera anello" : "Genera anelli",
                       systemImage: "arrow.trianglehead.clockwise") { calculate(loopMode) }
                    .buttonStyle(RouteEditorActionStyle(primary: preview == nil, fontSize: controlFontSize))
                    .accessibilityIdentifier("route.generateLoop")
                if preview != nil {
                    Spacer(minLength: 0)
                    Button("Salva percorso", systemImage: "checkmark") { showsSave = true }
                        .buttonStyle(RouteEditorActionStyle(primary: true, fontSize: controlFontSize))
                        .accessibilityIdentifier("route.save")
                }
            }
        }
        .disabled(isSaving)
    }

    private func modeButton(_ title: String, value: RouteMode, icon: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { mode = value }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: min(controlFontSize, 16), weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 28)
                .foregroundStyle(mode == value ? RunloopStyle.canvas : RunloopStyle.muted)
                .background(mode == value ? RunloopStyle.accent : .clear, in: .rect(cornerRadius: 7))
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(RunloopPressStyle())
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }

    @ViewBuilder private var selectionButtons: some View {
        Button("Centro mappa", systemImage: "mappin") {
            selection.select(selection.center, replacingStart: mode == .roundTrip)
        }
        .buttonStyle(RouteEditorActionStyle(fillsWidth: true, fontSize: controlFontSize))
        .accessibilityLabel("Usa il centro della mappa")
        .accessibilityIdentifier("route.useCenter")

        Button("La mia posizione", systemImage: "location") {
            selection.useCurrentLocation()
        }
        .buttonStyle(RouteEditorActionStyle(fillsWidth: true, fontSize: controlFontSize))
        .disabled(selection.isLocating)
        .accessibilityIdentifier("route.useLocation")
    }

    private var waypointList: some View {
        NavigationStack {
            List {
                Label("Partenza", systemImage: "flag.fill")
                ForEach(Array(selection.points.dropFirst().enumerated()), id: \.offset) { index, _ in
                    Label("Tappa \(index + 1)", systemImage: "mappin")
                }
                .onDelete { offsets in selection.removeStops(at: offsets) }
                .onMove { offsets, index in selection.moveStops(from: offsets, to: index) }
            }
            .navigationTitle("Punti del percorso")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { showsWaypoints = false } }
            }
        }
    }

    private func calculate(_ calculation: RouteMode) {
        guard let client = access.client, let start = selection.points.first, canCalculate, !isCalculating, !isSaving else { return }
        routingMessage = nil
        revealStartedAt = nil
        isCalculating = true
        let requestedPoints = selection.points
        let requestedMode = mode
        let requestedDistance = targetMeters
        let requestedUser = access.session?.user.id
        let seeds = calculation == .manual ? [] : reserveSeeds(for: calculation)
        let service = RoutingService(client: client)
        routeTask = Task {
            do {
                let results: [RoutePreview]
                switch calculation {
                case .manual:
                    results = [try await service.manual(waypoints: requestedPoints)]
                case .roundTrip, .waypointLoop:
                    results = try await service.loopAlternatives(start: start,
                        waypoints: calculation == .waypointLoop ? requestedPoints : nil,
                        targetDistanceMeters: requestedDistance, seeds: seeds)
                }
                guard !Task.isCancelled, access.session?.user.id == requestedUser,
                      mode == requestedMode, selection.points == requestedPoints,
                      mode == .manual || targetMeters == requestedDistance else { return }
                let fresh = calculation == .manual ? results : results.filter { seenLoops.insert($0.directionIndependentHash).inserted }
                if let first = fresh.first {
                    chosenPreview = 0
                    previews = fresh
                    previewMode = calculation
                    present(first)
                } else {
                    routingMessage = "Non ho trovato altre varianti. Riprova o sposta un punto."
                }
            } catch {
                guard !Task.isCancelled, access.session?.user.id == requestedUser,
                      mode == requestedMode, selection.points == requestedPoints,
                      mode == .manual || targetMeters == requestedDistance else { return }
                routingMessage = RoutingService.message(for: error)
            }
            isCalculating = false
            routeTask = nil
        }
    }

    private func reserveSeeds(for calculation: RouteMode) -> [Int] {
        if usedSeeds.isEmpty {
            let seeds = calculation == .roundTrip ? [0, 7, 11, 17] : Array(0..<Self.loopCandidateCount)
            usedSeeds.formUnion(seeds)
            return seeds
        }
        var seeds: [Int] = []
        while seeds.count < Self.loopCandidateCount {
            let seed = Int.random(in: 0...Int(Int32.max))
            if usedSeeds.insert(seed).inserted { seeds.append(seed) }
        }
        return seeds
    }

    private func present(_ preview: RoutePreview) {
        let alternatives = reduceMotion ? [] : revealAlternatives
        selection.frame(preview.coordinates + alternatives.flatMap { $0 })
        revealStartedAt = reduceMotion ? nil : .now
    }

    private func invalidatePreview() {
        routeTask?.cancel()
        routeTask = nil
        isCalculating = false
        previews = []
        previewMode = nil
        seenLoops.removeAll()
        usedSeeds.removeAll()
        revealStartedAt = nil
        chosenPreview = 0
        routingMessage = nil
        saveMessage = nil
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { saveMessage = "Scegli un nome per il percorso."; return }
        guard let client = access.client, let owner = access.session?.user.id, let preview, let previewMode, !isSaving else { return }
        isSaving = true
        saveMessage = nil
        defer { isSaving = false }
        let route = SavedRoute(
            id: existing?.id ?? draftID, ownerID: owner, name: trimmed, mode: previewMode,
            targetDistanceMeters: previewMode == .roundTrip ? targetMeters : nil,
            distanceMeters: preview.distanceMeters, waypoints: visiblePoints,
            geometry: RouteGeometry(coordinates: preview.coordinates), provider: preview.provider, revision: existing?.revision ?? 1
        )
        do {
            let stored = try await RouteLibraryService(client: client).save(route, replacing: existing)
            guard access.session?.user.id == owner else { return }
            onSave(stored)
            dismiss()
        } catch {
            saveMessage = RouteLibraryService.message(for: error)
        }
    }
}

@MainActor
@Observable
private final class RouteStartSelection: NSObject, @preconcurrency CLLocationManagerDelegate {
    private static let previewCenter = CLLocationCoordinate2D(latitude: 43.7358, longitude: 7.4236)
    private let locationManager = CLLocationManager()
    private var requestedFix = false

    var camera = MapCameraPosition.region(region(around: previewCenter))
    var center = previewCenter
    private(set) var points: [RouteCoordinate] = []
    private(set) var isLocating = false
    private(set) var locationMessage: String?

    init(points: [RouteCoordinate] = [], geometry: [RouteCoordinate] = []) {
        self.points = points
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        if !geometry.isEmpty { camera = .rect(routeMapRect(geometry)) }
    }

    func select(_ coordinate: CLLocationCoordinate2D, replacingStart: Bool) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        let point = RouteCoordinate(coordinate)
        if replacingStart {
            finishSelection()
            setStart(point)
            return
        }
        guard points.count < RoutingService.maxWaypoints else {
            locationMessage = "Puoi inserire fino a \(RoutingService.maxWaypoints) punti. Rimuovine uno per continuare."
            return
        }
        guard points.last != point else { return }
        finishSelection()
        points.append(point)
    }

    private func setStart(_ point: RouteCoordinate) {
        if points.isEmpty { points = [point] }
        else { points[0] = point }
    }

    private func finishSelection() {
        if requestedFix { locationManager.stopUpdatingLocation() }
        isLocating = false
        requestedFix = false
        locationMessage = nil
    }

    func recenter() {
        guard let start = points.first else { return }
        withAnimation { camera = .region(Self.region(around: start.location)) }
    }

    func undo() {
        guard !points.isEmpty else { return }
        finishSelection()
        points.removeLast()
    }

    func removeStops(at offsets: IndexSet) {
        let indices = IndexSet(offsets.map { $0 + 1 })
        points.remove(atOffsets: indices)
    }

    func moveStops(from offsets: IndexSet, to index: Int) {
        let indices = IndexSet(offsets.map { $0 + 1 })
        points.move(fromOffsets: indices, toOffset: index + 1)
    }

    func frame(_ coordinates: [RouteCoordinate]) {
        withAnimation { camera = .rect(routeMapRect(coordinates)) }
    }

    func useCurrentLocation() {
        guard !isLocating else { return }
        isLocating = true
        locationMessage = nil
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else {
            updateAuthorization(locationManager.authorizationStatus)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isLocating else { return }
        updateAuthorization(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isLocating, requestedFix else { return }
        guard let fix = locations.last, fix.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(fix.coordinate) else {
            finishWithError("Posizione non disponibile. Scegli la partenza sulla mappa.")
            return
        }
        requestedFix = false
        finishSelection()
        setStart(RouteCoordinate(fix.coordinate))
        recenter()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard isLocating, requestedFix else { return }
        finishWithError("Posizione non disponibile. Scegli la partenza sulla mappa.")
    }

    private func updateAuthorization(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            guard !requestedFix else { return }
            requestedFix = true
            locationManager.requestLocation()
        case .notDetermined:
            break
        default:
            finishWithError("Accesso alla posizione disattivato. Puoi scegliere la partenza sulla mappa.")
        }
    }

    private func finishWithError(_ message: String) {
        isLocating = false
        requestedFix = false
        locationMessage = message
    }

    private static func region(around center: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: center, latitudinalMeters: 2800, longitudinalMeters: 2800)
    }
}

private struct RouteEditorActionStyle: ButtonStyle {
    var primary = false
    var fillsWidth = false
    let fontSize: CGFloat
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return configuration.label
            .font(.system(size: min(fontSize, 16), weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 9)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 30)
            .foregroundStyle(primary ? RunloopStyle.canvas : RunloopStyle.text)
            .background(primary ? RunloopStyle.accent : RunloopStyle.panel, in: shape)
            .overlay { if !primary { shape.strokeBorder(RunloopStyle.border) } }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
            .opacity(enabled ? (configuration.isPressed ? 0.76 : 1) : 0.48)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct RouteReveal: View {
    private static let routeDrawDuration = 0.82
    private static let routeDelay = 0.83
    private static let branchDrawDuration = 0.67
    private static let branchLeadIn = 0.14
    private static let branchStagger = 0.17
    private static let branchFadeStart = 1.10
    private static let branchFadeDuration = 1.02
    private static let branchColor = Color(red: 0.38, green: 0.91, blue: 0.91)

    private let coordinates: [RouteCoordinate]
    private let alternatives: [[RouteCoordinate]]
    let startedAt: Date
    let proxy: MapProxy

    init(coordinates: [RouteCoordinate], alternatives: [[RouteCoordinate]], startedAt: Date, proxy: MapProxy) {
        self.coordinates = Self.sample(coordinates, limit: alternatives.isEmpty ? 900 : 600)
        self.alternatives = alternatives.map { Self.sample($0, limit: 190) }
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
                    context.stroke(branch, with: .color(Self.branchColor.opacity(0.94 * opacity)),
                                   style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                    drawHead(of: branch, progress: progress, radius: 2.5, in: context)
                }

                let delay = alternatives.isEmpty ? 0 : Self.routeDelay
                let progress = (elapsed - delay) / Self.routeDrawDuration
                guard let stroke = trace(coordinates, progress: progress) else { return }
                context.stroke(stroke, with: .color(.black.opacity(0.92)),
                               style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                context.stroke(stroke, with: .color(RunloopStyle.accent),
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
