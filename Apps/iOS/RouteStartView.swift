import CoreLocation
import MapKit
import RunloopCore
import SwiftUI
import UIKit

struct RouteStartView: View {
    @Environment(\.runloopAccent) private var accent

    @Environment(AccountAccess.self) private var access
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var controlFontSize = 13.0
    @Namespace private var variantSelection
    private let existing: SavedRoute?
    private let onSave: (SavedRoute) -> Void
    @State private var selection = RouteStartSelection()
    @State private var mode = RouteMode.manual
    @State private var targetMeters = 5000
    @State private var previews: [RoutePreview] = []
    @State private var chosenPreview = 0
    @State private var previewMode: RouteMode?
    @State private var loopSearch = LoopSearch()
    @State private var revealStartedAt: Date?
    @State private var revealsAlternatives = false
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
                _loopSearch = State(initialValue: LoopSearch(existing: existing.preview))
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
                        .stroke(accent.opacity(isRevealing ? 0 : 1), lineWidth: 4)
                }
                ForEach(Array(visiblePoints.enumerated()), id: \.offset) { index, point in
                    Annotation(index == 0 ? "Partenza" : "Tappa \(index)", coordinate: point.location, anchor: .bottom) {
                        RouteMapPin(index: index)
                    }
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
            .modifier(RoutePlacementFeedback(points: selection.points, proxy: proxy))
            .mapControls { MapCompass() }
            .overlay {
                if let started = revealStartedAt, isRevealing, let preview {
                    RouteReveal(coordinates: preview.coordinates, alternatives: revealsAlternatives ? revealAlternatives : [],
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
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(existing == nil ? "Nuovo percorso" : "Modifica percorso")
                    .font(RunloopType.sectionTitle)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .onChange(of: selection.points) { invalidatePreview() }
        .onChange(of: access.session?.user.id) { invalidatePreview() }
        .onChange(of: targetMeters) { if mode == .roundTrip { invalidatePreview() } }
        .task(id: revealStartedAt) {
            guard let started = revealStartedAt else { return }
            let branchCount = revealsAlternatives ? revealAlternatives.count : 0
            try? await Task.sleep(for: .seconds(RouteReveal.duration(alternativeCount: branchCount)))
            if !Task.isCancelled, revealStartedAt == started { revealStartedAt = nil }
        }
        .onDisappear {
            routeTask?.cancel()
            routeTask = nil
            isCalculating = false
            revealStartedAt = nil
        }
        .sensoryFeedback(.selection, trigger: mode)
        .sensoryFeedback(.selection, trigger: selection.points) { _, current in !current.isEmpty }
        .sensoryFeedback(.selection, trigger: preview?.id) { _, current in current != nil }
        .sheet(isPresented: $showsWaypoints) { waypointList }
        .alert("Salva percorso", isPresented: $showsSave) {
            TextField("Nome del percorso", text: $name)
            Button("Annulla", role: .cancel) {}
            Button("Salva") { Task { await save() } }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 3) {
            if isSaving {
                ProgressView("Salvataggio…")
            } else if let saveMessage {
                Text(saveMessage).font(.subheadline).foregroundStyle(RunloopStyle.danger)
            }
            HStack(spacing: 4) {
                modeButton("Manuale", value: .manual)
                modeButton("Ad anello", value: .roundTrip)
            }
            .background {
                GeometryReader { geometry in
                    let segmentWidth = max(0, (geometry.size.width - 4) / 2)
                    RoundedRectangle(cornerRadius: RunloopStyle.controlRadius)
                        .fill(RunloopStyle.raised)
                        .frame(width: segmentWidth, height: 28)
                        .frame(maxHeight: .infinity)
                        .offset(x: mode == .manual ? 0 : segmentWidth + 4)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 3)
            .background {
                RoundedRectangle(cornerRadius: RunloopStyle.radius)
                    .fill(RunloopStyle.panel)
                    .overlay { RoundedRectangle(cornerRadius: RunloopStyle.radius).strokeBorder(RunloopStyle.border) }
                    .frame(height: 34)
                    .allowsHitTesting(false)
            }
            .accessibilityIdentifier("route.mode")

            HStack {
                routeSummary
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
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("route.editPoints")
                        }
                        Button("Annulla ultimo punto", systemImage: "arrow.uturn.backward") { selection.undo() }
                            .labelStyle(.iconOnly)
                            .font(.footnote.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .buttonStyle(RunloopPressStyle())
                            .accessibilityIdentifier("route.undoPoint")
                    }
                    Button("Centra sulla partenza", systemImage: "scope") { selection.recenter(animated: !reduceMotion) }
                        .labelStyle(.iconOnly)
                        .font(.footnote.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .buttonStyle(RunloopPressStyle())
                        .accessibilityIdentifier("route.recenter")
                }
            }
            .frame(minHeight: 44)

            if let message = selection.locationMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(RunloopStyle.muted)
                    .accessibilityIdentifier("route.locationStatus")
                if selection.showsLocationSettings, let settings = URL(string: UIApplication.openSettingsURLString) {
                    Link("Apri impostazioni", destination: settings)
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("route.locationSettings")
                }
            }

            if let routingMessage {
                Text(routingMessage)
                    .font(.subheadline)
                    .foregroundStyle(RunloopStyle.muted)
                    .accessibilityIdentifier("route.routingStatus")
                    .transition(.opacity)
            }

            ZStack(alignment: .leading) {
                Stepper(value: $targetMeters, in: 500...50000, step: 500) {
                    HStack(spacing: 8) {
                        Text("Obiettivo").font(RunloopType.control).foregroundStyle(RunloopStyle.muted)
                        Text(routeDistanceText(Double(targetMeters)))
                            .font(RunloopType.readout)
                            .contentTransition(reduceMotion ? .identity : .numericText())
                            .animation(reduceMotion ? nil : RunloopMotion.status, value: targetMeters)
                    }
                    .accessibilityElement(children: .combine)
                }
                .accessibilityIdentifier("route.targetDistance")
                .opacity(!selection.isLocating && mode == .roundTrip ? 1 : 0)
                .allowsHitTesting(!selection.isLocating && mode == .roundTrip)
                .accessibilityHidden(selection.isLocating || mode != .roundTrip)

                Text(manualHint)
                    .font(.footnote)
                    .foregroundStyle(RunloopStyle.muted)
                    .opacity(!selection.isLocating && mode == .manual ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(selection.isLocating || mode != .manual)

                if selection.isLocating {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Ricerca della posizione…").font(.footnote)
                    }
                    .foregroundStyle(RunloopStyle.muted)
                    .accessibilityElement(children: .combine)
                }
            }

            if previews.count > 1 {
                alternativePicker
                    .transition(.opacity)
            }

            HStack(spacing: 0) { selectionButtons }
                .background {
                    RoundedRectangle(cornerRadius: RunloopStyle.controlRadius)
                        .fill(RunloopStyle.panel)
                        .frame(height: 30)
                        .allowsHitTesting(false)
                }

            routeActions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RunloopStyle.canvas)
        .overlay(alignment: .top) { Divider().overlay(RunloopStyle.border) }
    }

    @ViewBuilder
    private var routeSummary: some View {
        if let preview {
            VStack(alignment: .leading, spacing: 1) {
                Text(routeDistanceText(preview.distanceMeters))
                    .font(RunloopType.compactMetric)
                    .foregroundStyle(RunloopStyle.text)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : RunloopMotion.status, value: preview.distanceMeters)
                    .accessibilityIdentifier("route.distance")
                Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    .font(.caption2).foregroundStyle(RunloopStyle.muted)
            }
            .transition(.opacity)
        } else {
            Text(selection.points.isEmpty ? "Scegli la partenza" : "Partenza selezionata")
                .font(RunloopType.control)
                .accessibilityIdentifier("route.startStatus")
                .transition(.opacity)
        }
    }

    private var manualHint: String {
        switch selection.points.count {
        case 0: "Tocca la mappa o scegli qui sotto."
        case 1: "Tocca la mappa per aggiungere una tappa."
        default: "Punti sul percorso: \(selection.points.count)"
        }
    }

    @ViewBuilder
    private var alternativePicker: some View {
        if previews.count > 4 || dynamicTypeSize.isAccessibilitySize {
            ScrollView(.horizontal) {
                alternativeButtons(fillsWidth: false)
            }
            .id(previews.first?.id)
            .accessibilityLabel("Alternative")
            .accessibilityIdentifier("route.alternatives")
        } else {
            alternativeButtons(fillsWidth: true)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Alternative")
                .accessibilityIdentifier("route.alternatives")
        }
    }

    private func alternativeButtons(fillsWidth: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(previews.enumerated()), id: \.element.id) { index, option in
                let distance = routeDistanceText(option.distanceMeters)
                let selected = index == chosenPreview
                Button {
                    choosePreview(index)
                } label: {
                    RouteVariantLabel(index: index, distance: distance, selected: selected,
                                      fillsWidth: fillsWidth, namespace: variantSelection)
                }
                .buttonStyle(RunloopPressStyle())
                .accessibilityLabel("Alternativa \(index + 1) di \(previews.count), \(distance)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("route.alternative.\(index + 1)")
            }
        }
    }

    private func choosePreview(_ index: Int) {
        guard previews.indices.contains(index), index != chosenPreview else { return }
        withAnimation(reduceMotion ? nil : RunloopMotion.status) { chosenPreview = index }
        present(previews[index], explore: false)
    }

    private var routeActions: some View {
        HStack(spacing: 8) {
            if canCalculate && (access.session == nil || access.client == nil) {
                NavigationLink("Accedi per calcolare") { AccountView() }
            } else {
                let loopMode: RouteMode = mode == .manual ? .waypointLoop : .roundTrip
                if mode == .manual && preview == nil {
                    Button("Calcola tratta", systemImage: "arrow.forward") { calculate(.manual) }
                        .buttonStyle(RouteEditorActionStyle(fontSize: controlFontSize))
                        .accessibilityIdentifier("route.calculate")
                        .disabled(!canCalculate || isCalculating)
                }
                if isCalculating {
                    ProgressView("Calcolo percorso…").font(RunloopType.control)
                } else {
                    Button(previewMode == loopMode ? "Altri anelli" : mode == .manual ? "Genera anello" : "Genera anelli",
                           systemImage: "arrow.trianglehead.clockwise") { calculate(loopMode) }
                        .buttonStyle(RouteEditorActionStyle(primary: preview == nil, fontSize: controlFontSize))
                        .accessibilityIdentifier("route.generateLoop")
                        .disabled(!canCalculate)
                }
                if preview != nil {
                    Spacer(minLength: 0)
                    Button("Salva percorso", systemImage: "checkmark") { showsSave = true }
                        .buttonStyle(RouteEditorActionStyle(primary: true, fontSize: controlFontSize))
                        .accessibilityIdentifier("route.save")
                        .disabled(isCalculating)
                }
            }
        }
        .frame(minHeight: 44)
        .disabled(isSaving)
    }

    private func modeButton(_ title: String, value: RouteMode) -> some View {
        Button {
            guard mode != value else { return }
            withAnimation(reduceMotion ? nil : RunloopMotion.editorLayout) {
                mode = value
                invalidatePreview()
            }
        } label: {
            HStack(spacing: 6) {
                RouteModeGlyph(mode: value)
                Text(title)
            }
                .font(.system(size: min(controlFontSize, 16), weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 28)
                .foregroundStyle(mode == value ? accent : RunloopStyle.muted)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }

    @ViewBuilder private var selectionButtons: some View {
        Button("Centro mappa", systemImage: "mappin") {
            selection.select(selection.center, replacingStart: mode == .roundTrip)
        }
        .buttonStyle(RouteEditorActionStyle(fillsWidth: true, fontSize: controlFontSize))
        .accessibilityLabel("Usa il centro della mappa")
        .accessibilityIdentifier("route.useCenter")

        Rectangle().fill(RunloopStyle.border).frame(width: 1, height: 16)
            .accessibilityHidden(true)

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
        let seeds = calculation == .manual ? [] : loopSearch.reserveSeeds()
        let previousLoop = previewMode == calculation ? preview : nil
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
                let fresh: [RoutePreview]
                if calculation == .manual {
                    fresh = results
                } else {
                    fresh = loopSearch.rank(results, previous: previousLoop,
                                      reference: calculation == .waypointLoop ? requestedPoints.last ?? start : start,
                                      targetDistance: calculation == .roundTrip ? Double(requestedDistance) : nil)
                }
                withAnimation(reduceMotion ? nil : RunloopMotion.editorLayout) {
                    if let first = fresh.first {
                        chosenPreview = 0
                        previews = fresh
                        previewMode = calculation
                        present(first, explore: true)
                    } else {
                        routingMessage = "Non ho trovato altre varianti. Riprova o sposta un punto."
                    }
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

    private func present(_ preview: RoutePreview, explore: Bool) {
        let alternatives = reduceMotion ? [] : revealAlternatives
        selection.frame(preview.coordinates + alternatives.flatMap { $0 }, animated: !reduceMotion)
        revealsAlternatives = explore
        revealStartedAt = reduceMotion ? nil : .now
    }

    private func invalidatePreview() {
        routeTask?.cancel()
        routeTask = nil
        isCalculating = false
        previews = []
        previewMode = nil
        loopSearch = LoopSearch()
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
    private let locationManager = CLLocationManager()
    private var requestedFix = false

    var camera = MapCameraPosition.region(region(around: routePlanningStart))
    var center = routePlanningStart
    private(set) var points: [RouteCoordinate] = []
    private(set) var isLocating = false
    private(set) var showsLocationSettings = false
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
        guard points.count < RouteDraft.maximumWaypoints else {
            showsLocationSettings = false
            locationMessage = "Puoi inserire fino a \(RouteDraft.maximumWaypoints) punti. Rimuovine uno per continuare."
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
        showsLocationSettings = false
        locationMessage = nil
    }

    func recenter(animated: Bool) {
        guard let start = points.first else { return }
        withAnimation(animated ? RunloopMotion.status : nil) { camera = .region(Self.region(around: start.location)) }
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

    func frame(_ coordinates: [RouteCoordinate], animated: Bool) {
        withAnimation(animated ? RunloopMotion.status : nil) { camera = .rect(routeMapRect(coordinates)) }
    }

    func useCurrentLocation() {
        guard !isLocating else { return }
        isLocating = true
        showsLocationSettings = false
        locationMessage = nil
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else {
            updateAuthorization(locationManager.authorizationStatus)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if showsLocationSettings && manager.authorizationStatus != .denied {
            showsLocationSettings = false
            locationMessage = nil
        }
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
        recenter(animated: !UIAccessibility.isReduceMotionEnabled)
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
        case .denied:
            finishWithError("Accesso alla posizione disattivato. Puoi scegliere la partenza sulla mappa.")
            showsLocationSettings = true
        default:
            finishWithError("Posizione non disponibile. Scegli la partenza sulla mappa.")
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
    @Environment(\.runloopAccent) private var accent
    var primary = false
    var fillsWidth = false
    let fontSize: CGFloat
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: RunloopStyle.controlRadius)
        return configuration.label
            .font(.system(size: min(fontSize, 16), weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 9)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 30)
            .foregroundStyle(primary ? RunloopStyle.canvas : RunloopStyle.text)
            .background(primary ? accent : fillsWidth ? Color.clear : RunloopStyle.panel, in: shape)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
            .opacity(enabled ? (configuration.isPressed ? 0.76 : 1) : 0.48)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .animation(reduceMotion ? nil : RunloopMotion.press, value: configuration.isPressed)
    }
}
