import MapKit
import RunloopCore
import SwiftUI

@main
struct RunloopApp: App {
    @State private var inbox = WatchRouteInbox()
    @AppStorage(RunloopAccent.storageKey) private var accentChoice = RunloopAccent.defaultChoice
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if inbox.runs.isPresented {
                    RunSessionScreen(runs: inbox.runs)
                } else {
                    library
                }
            }
            .preferredColorScheme(.dark)
            .modifier(RequestLocationPermissionOnLaunch())
            .tint(accentChoice.color)
            .environment(\.runloopAccent, accentChoice.color)
            .onChange(of: inbox.runs.local.phase) { _, phase in
                if phase == .discarded { inbox.runs.rememberCompletion() }
                if phase == .saved {
                    inbox.runs.rememberCompletion()
                    inbox.syncWorkouts()
                }
            }
            .task(id: scenePhase) {
                if scenePhase == .active { await inbox.runs.monitor() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { inbox.syncWorkouts() }
            }
        }
    }

    private var library: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Button("Corsa libera", systemImage: "figure.run") {
                        inbox.runs.start(route: nil, ownerID: inbox.currentOwner)
                    }
                    .buttonStyle(RunloopButtonStyle())
                    .disabled(inbox.runs.isPresented)

                    if inbox.workouts.pendingCount > 0 {
                        Button(inbox.workouts.needsRetry ? "Riprova invio corse" : "Corse in attesa di invio", systemImage: "arrow.trianglehead.clockwise") {
                            inbox.syncWorkouts()
                        }
                        .buttonStyle(RunloopButtonStyle(kind: .secondary))
                    }

                    HStack(spacing: 6) {
                        Text("Percorsi").font(RunloopType.sectionTitle).accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                        NavigationLink {
                            WatchRoutePlanner(inbox: inbox)
                        } label: {
                            Label("Nuovo", systemImage: "plus")
                                .accessibilityLabel("Nuovo percorso")
                        }
                        .buttonStyle(RunloopButtonStyle(kind: .secondary, compact: true))
                        .accessibilityIdentifier("watch.library.newRoute")
                    }
                    if inbox.readFailed {
                        Text("Impossibile leggere i percorsi.")
                            .font(.footnote).foregroundStyle(RunloopStyle.muted)
                    } else if inbox.routes.isEmpty {
                        Text("Crea il primo percorso qui o invialo dall’iPhone.")
                            .font(.footnote).foregroundStyle(RunloopStyle.muted)
                    }
                    ForEach(inbox.routes, id: \.entityID) { route in
                        NavigationLink {
                            if let latest = inbox.routes.first(where: { $0.entityID == route.entityID }) {
                                WatchRouteDetail(route: latest, inbox: inbox) {
                                    inbox.runs.start(route: latest, ownerID: inbox.currentOwner)
                                }
                            } else {
                                ContentUnavailableView("Percorso non disponibile", systemImage: "map")
                            }
                        } label: {
                            routeRow(route.payload, featured: route.entityID == inbox.routes.first?.entityID)
                        }
                        .buttonStyle(RunloopPressStyle())
                    }
                    NavigationLink {
                        WatchRunHistory(inbox: inbox)
                    } label: {
                        Label("Allenamenti", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(RunloopButtonStyle(kind: .secondary))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .runloopCanvas()
            .navigationTitle("Runloop")
        }
    }

    private func routeRow(_ route: RouteTransfer, featured: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if featured {
                RunloopTrace(coordinates: route.geometry.coordinates, showsGrid: true, lineWidth: 2.5)
                    .frame(height: 62)
                    .clipShape(.rect(cornerRadius: RunloopStyle.radius))
                    .runloopPanel()
            }
            HStack(spacing: 8) {
                if !featured {
                    RunloopTrace(coordinates: route.geometry.coordinates, color: RunloopStyle.muted, lineWidth: 2)
                        .frame(width: 24, height: 32)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(route.name).font(.footnote.weight(.bold))
                    Text(routeSummary(distance: route.distanceMeters, mode: route.mode)).font(RunloopType.readout).foregroundStyle(RunloopStyle.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(RunloopStyle.muted)
            }
            .padding(.vertical, 2)
        }
        .frame(minHeight: 44)
        .foregroundStyle(RunloopStyle.text)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct WatchRouteDetail: View {
    @Environment(\.runloopAccent) private var accent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let route: SyncEnvelope<RouteTransfer>
    let inbox: WatchRouteInbox
    let start: () -> Void
    @State private var showsMap = false

    private var locations: [CLLocationCoordinate2D] {
        route.payload.geometry.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(route.payload.name).font(RunloopType.sectionTitle).accessibilityAddTraits(.isHeader)
                Text(routeDistanceText(route.payload.distanceMeters))
                    .font(RunloopType.compactMetric)
                    .foregroundStyle(accent)

                if showsMap {
                    Map(initialPosition: .rect(mapRect), interactionModes: []) {
                        MapPolyline(coordinates: locations).stroke(accent, lineWidth: 3)
                        if let start = locations.first {
                            Annotation("Partenza", coordinate: start, anchor: .bottom) { RouteMapPin(index: 0) }
                        }
                    }
                    .mapStyle(.standard(emphasis: .muted))
                    .frame(height: 76)
                    .clipShape(.rect(cornerRadius: RunloopStyle.radius))
                } else {
                    RunloopTrace(coordinates: route.payload.geometry.coordinates, showsGrid: true)
                        .frame(height: 76)
                        .clipShape(.rect(cornerRadius: RunloopStyle.radius))
                        .runloopPanel()
                        .accessibilityRepresentation { Text("Traccia del percorso disponibile offline") }
                }

                Button("Inizia corsa", systemImage: "figure.run", action: start)
                    .buttonStyle(RunloopButtonStyle())
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(spacing: 6))
                layout {
                    Button(showsMap ? "Traccia" : "Mappa") {
                        showsMap.toggle()
                    }
                    .accessibilityLabel(showsMap ? "Mostra traccia" : "Apri mappa")
                    .buttonStyle(RunloopButtonStyle(kind: .secondary, compact: true))
                    .sensoryFeedback(.selection, trigger: showsMap)
                    NavigationLink {
                        WatchRoutePlanner(inbox: inbox, source: route.payload)
                    } label: {
                        Text("Variante").accessibilityLabel("Crea variante del percorso")
                    }
                    .buttonStyle(RunloopButtonStyle(kind: .secondary, compact: true))
                }
                if route.payload.provider == "graphhopper" {
                    Text("© OpenStreetMap contributors").font(.caption2).foregroundStyle(RunloopStyle.muted)
                }
            }
            .padding(.horizontal, 8)
        }
        .runloopCanvas()
        .navigationTitle("Percorso")
    }

    private var mapRect: MKMapRect {
        let rect = MKPolyline(coordinates: locations, count: locations.count).boundingMapRect
        return rect.insetBy(dx: -max(180, rect.width * 0.2), dy: -max(180, rect.height * 0.2))
    }
}

private struct WatchRunHistory: View {
    let inbox: WatchRouteInbox
    @State private var local: [RunBrief] = []

    private var entries: [RunBrief] {
        let phoneIDs = Set(inbox.recent.map(\.id))
        return (inbox.recent + local.filter { !phoneIDs.contains($0.id) }).sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        List {
            if entries.isEmpty { Text("Nessun allenamento") }
            ForEach(entries) { entry in
                NavigationLink {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(routeDistanceText(entry.distance)).font(RunloopType.metric)
                        Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Tempo attivo", value: Duration.seconds(entry.duration).formatted(.time(pattern: .hourMinuteSecond)))
                        LabeledContent("Passo medio", value: runPaceText(duration: entry.duration, distance: entry.distance))
                        Text(entry.source.displayName).foregroundStyle(RunloopStyle.muted)
                    }.font(.footnote).padding(.horizontal, 6).navigationTitle("Corsa")
                } label: {
                    VStack(alignment: .leading) {
                        Text(routeDistanceText(entry.distance)).font(RunloopType.compactMetric)
                        Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("Allenamenti")
        .task(id: inbox.currentOwner) { local = inbox.workouts.localHistory(owner: inbox.currentOwner) }
        .onChange(of: inbox.workouts.pendingCount) { local = inbox.workouts.localHistory(owner: inbox.currentOwner) }
    }
}
