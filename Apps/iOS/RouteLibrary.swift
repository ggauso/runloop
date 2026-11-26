import Foundation
import MapKit
import RunloopCore
import Supabase
import SwiftUI

struct SavedRoute: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let ownerID: UUID
    let name: String
    let mode: RouteMode
    let targetDistanceMeters: Int?
    let distanceMeters: Double
    let waypoints: [RouteCoordinate]
    let geometry: RouteGeometry
    let provider: String
    let revision: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, mode, waypoints, geometry, provider, revision
        case ownerID = "owner_id"
        case targetDistanceMeters = "target_distance_m"
        case distanceMeters = "distance_m"
    }

    func encode(to encoder: any Encoder) throws {
        var row = encoder.container(keyedBy: CodingKeys.self)
        try row.encode(id, forKey: .id)
        try row.encode(ownerID, forKey: .ownerID)
        try row.encode(name, forKey: .name)
        try row.encode(mode, forKey: .mode)
        try row.encode(targetDistanceMeters, forKey: .targetDistanceMeters)
        try row.encode(distanceMeters, forKey: .distanceMeters)
        try row.encode(waypoints, forKey: .waypoints)
        try row.encode(geometry, forKey: .geometry)
        try row.encode(provider, forKey: .provider)
        try row.encode(revision, forKey: .revision)
    }

    var preview: RoutePreview {
        RoutePreview(coordinates: geometry.coordinates, distanceMeters: distanceMeters, provider: provider)
    }

    var watchEnvelope: SyncEnvelope<RouteTransfer> {
        let payload = RouteTransfer(ownerID: ownerID, name: name, distanceMeters: distanceMeters,
                                    geometry: geometry, provider: provider, mode: mode,
                                    waypoints: waypoints, targetDistanceMeters: targetDistanceMeters)
        return SyncEnvelope(entityType: "route", entityID: id, revision: revision, payload: payload)
    }
}

struct RouteLibraryService {
    let client: SupabaseClient

    func list() async throws -> [SavedRoute] {
        try await client.from("routes").select().order("updated_at", ascending: false).execute().value
    }

    func save(_ route: SavedRoute, replacing previous: SavedRoute?) async throws -> SavedRoute {
        if let previous {
            return try await client.from("routes").update(route)
                .eq("id", value: previous.id).eq("revision", value: previous.revision)
                .select().single().execute().value
        }
        return try await client.from("routes").upsert(route, onConflict: "id")
            .select().single().execute().value
    }

    func rename(_ route: SavedRoute, to name: String) async throws -> SavedRoute {
        try await client.from("routes").update(["name": name]).eq("id", value: route.id)
            .select().single().execute().value
    }

    func saveFromWatch(_ route: SavedRoute) async throws -> SavedRoute {
        // A repeat after a lost reply returns the same route without overwriting any edits.
        _ = try await client.from("routes").upsert(route, onConflict: "id", ignoreDuplicates: true).execute()
        return try await client.from("routes").select().eq("id", value: route.id)
            .eq("owner_id", value: route.ownerID).single().execute().value
    }

    func delete(_ route: SavedRoute) async throws {
        _ = try await client.from("routes").delete().eq("id", value: route.id).execute()
    }

    static func message(for error: any Error) -> String {
        if (error as NSError).domain == NSURLErrorDomain { return "Connessione non disponibile. Riprova quando torni online." }
        if let error = error as? PostgrestError, error.code == "PGRST116" {
            return "Il percorso è cambiato. Riaprilo dalla libreria prima di riprovare."
        }
        return "Non è stato possibile completare l’operazione. Riprova tra poco."
    }
}

struct RouteLibraryView: View {
    @Binding var editorVisible: Bool
    @Environment(AccountAccess.self) private var access
    @Environment(PhoneWatchTransfer.self) private var watchTransfer
    @State private var routes: [SavedRoute] = []
    @State private var snapshotOwner: UUID?
    @State private var isLoading = false
    @State private var message: String?
    @State private var revision = 0

    private enum Destination: Hashable { case create, saved(UUID) }
    @State private var path: [Destination] = []
    @Environment(\.runloopAccent) private var accent

    var body: some View {
        NavigationStack(path: $path) {
            library.navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .create:
                    RouteStartView(editorVisible: $editorVisible) { route in
                        replace(route)
                        path = [.saved(route.id)]
                    }
                case .saved(let id):
                    if let route = routes.first(where: { $0.id == id }) {
                        SavedRouteDetail(route: route, editorVisible: $editorVisible, onChange: replace, onDelete: remove)
                    } else {
                        ContentUnavailableView("Percorso non disponibile", systemImage: "map")
                    }
                }
            }
        }
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RunloopHeading(context: "Runloop  /  Libreria", title: "Percorsi")

                if let owner = access.session?.user.id, owner == snapshotOwner, let latest = routes.first {
                    routeLink(latest, featured: true)
                }
                VStack(spacing: 10) {
                    newRouteLink
                    Button("Corsa libera", systemImage: "figure.run") {
                        watchTransfer.runs.start(route: nil, ownerID: access.session?.user.id)
                    }
                    .buttonStyle(RunloopButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("run.free")
                }

                if let owner = access.session?.user.id {
                    if owner == snapshotOwner, !routes.isEmpty {
                        if routes.count > 1 {
                            Text("ALTRI PERCORSI").font(RunloopType.readout).foregroundStyle(RunloopStyle.muted)
                            VStack(spacing: 0) {
                                ForEach(routes.dropFirst()) { route in
                                    Divider().overlay(RunloopStyle.border)
                                    routeLink(route, featured: false)
                                }
                            }
                        }
                    } else if isLoading || owner != snapshotOwner {
                        ProgressView("Caricamento percorsi…")
                    } else if message == nil {
                        Text("Nessun percorso salvato")
                            .font(.subheadline)
                            .foregroundStyle(RunloopStyle.muted)
                    }
                    if let message {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message).font(.footnote).foregroundStyle(RunloopStyle.muted)
                            Button("Riprova", systemImage: "arrow.clockwise") { Task { await refresh() } }
                                .buttonStyle(RunloopButtonStyle(kind: .secondary, compact: true))
                        }
                    }
                } else if !access.isRestoring {
                    NavigationLink("Accedi per vedere i percorsi salvati") { AccountView() }
                        .buttonStyle(RunloopButtonStyle(kind: .secondary))
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
        .runloopCanvas()
        .navigationTitle("I miei percorsi")
        .toolbar(.hidden, for: .navigationBar)
        .task(id: access.session?.user.id) { await refresh() }
        .onChange(of: watchTransfer.watchRouteRevision) {
            revision += 1
            Task { await refresh() }
        }
        .refreshable { await refresh() }
    }

    private var newRouteLink: some View {
        NavigationLink(value: Destination.create) {
            Label("Nuovo percorso", systemImage: "plus")
        }
        .buttonStyle(RunloopButtonStyle())
        .accessibilityIdentifier("library.newRoute")
    }

    private func routeLink(_ route: SavedRoute, featured: Bool) -> some View {
        NavigationLink(value: Destination.saved(route.id)) {
            if featured {
                VStack(alignment: .leading, spacing: 12) {
                    SavedRouteMap(route: route, interactive: false)
                        .frame(height: 240)
                        .clipShape(.rect(cornerRadius: RunloopStyle.radius))
                        .overlay(alignment: .topLeading) {
                            Text(route.mode == .manual ? "TRATTA" : "AD ANELLO")
                                .font(RunloopType.readout).padding(7)
                                .foregroundStyle(accent)
                                .background(RunloopStyle.canvas, in: .rect(cornerRadius: 5)).padding(10)
                        }
                        .allowsHitTesting(false).accessibilityHidden(true)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(route.name).font(RunloopType.display(size: 36, relativeTo: .title)).fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 8)
                            Text(routeDistanceText(route.distanceMeters)).font(RunloopType.metric).foregroundStyle(accent).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(route.name).font(RunloopType.sectionTitle)
                            Text(routeDistanceText(route.distanceMeters)).font(RunloopType.metric).foregroundStyle(accent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let start = route.waypoints.first ?? route.geometry.coordinates.first {
                        DepartureLabel(point: start).font(.subheadline).foregroundStyle(RunloopStyle.muted)
                    }
                }
                .foregroundStyle(RunloopStyle.text).contentShape(.rect)
            } else {
                HStack(spacing: 14) {
                    RunloopTrace(coordinates: route.geometry.coordinates, color: RunloopStyle.muted, lineWidth: 2)
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(route.name).font(.subheadline.weight(.semibold))
                        Text(routeSummary(distance: route.distanceMeters, mode: route.mode))
                            .font(RunloopType.readout)
                            .foregroundStyle(RunloopStyle.muted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        .foregroundStyle(RunloopStyle.muted)
                }
                .foregroundStyle(RunloopStyle.text)
                .padding(.vertical, 10)
                .contentShape(.rect)
            }
        }
        .buttonStyle(RunloopPressStyle())
    }

    private func refresh() async {
        let currentOwner = access.session?.user.id
        if snapshotOwner != currentOwner {
            routes = currentOwner.map(RouteCache.load) ?? []
            snapshotOwner = currentOwner
        }
        message = nil
        guard let owner = snapshotOwner, let client = access.client else { return }
        let requestedRevision = revision
        isLoading = true
        defer { if snapshotOwner == owner { isLoading = false } }
        do {
            let result = try await RouteLibraryService(client: client).list()
            guard !Task.isCancelled, access.session?.user.id == owner, requestedRevision == revision else { return }
            routes = result.filter { $0.ownerID == owner }
            RouteCache.save(routes, owner: owner)
        } catch {
            guard !Task.isCancelled, access.session?.user.id == owner else { return }
            message = RouteLibraryService.message(for: error)
        }
    }

    private func replace(_ route: SavedRoute) {
        guard route.ownerID == access.session?.user.id else { return }
        revision += 1
        routes.removeAll { $0.id == route.id }
        routes.insert(route, at: 0)
        RouteCache.save(routes, owner: route.ownerID)
    }

    private func remove(_ id: UUID) {
        guard let owner = access.session?.user.id, owner == snapshotOwner else { return }
        revision += 1
        routes.removeAll { $0.id == id }
        RouteCache.save(routes, owner: owner)
    }
}

private enum RouteCache {
    static func load(_ owner: UUID) -> [SavedRoute] {
        guard let data = try? Data(contentsOf: file(for: owner)),
              let routes = try? JSONDecoder().decode([SavedRoute].self, from: data) else { return [] }
        return routes.filter { $0.ownerID == owner }
    }

    static func save(_ routes: [SavedRoute], owner: UUID) {
        let url = file(for: owner)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(routes).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // The saved cloud record remains available when the device reconnects.
        }
    }

    private static func file(for owner: UUID) -> URL {
        URL.applicationSupportDirectory.appending(path: "Runloop/RouteCache/\(owner.uuidString).json")
    }
}

private struct SavedRouteDetail: View {
    @Environment(\.runloopAccent) private var accent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AccountAccess.self) private var access
    @Environment(PhoneWatchTransfer.self) private var watchTransfer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State var route: SavedRoute
    @Binding var editorVisible: Bool
    var onChange: (SavedRoute) -> Void
    var onDelete: (UUID) -> Void
    @State private var name = ""
    @State private var showsRename = false
    @State private var showsDelete = false
    @State private var isWorking = false
    @State private var message: String?
    private var watchStatus: PhoneWatchTransfer.Delivery? { watchTransfer.status(for: route) }

    var body: some View {
        Group {
            if route.ownerID == access.session?.user.id {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        RunloopHeading(context: "Percorso salvato", title: route.name)
                        Text(route.mode == .manual ? "TRATTA" : "AD ANELLO")
                            .font(RunloopType.readout).foregroundStyle(RunloopStyle.muted)
                        SavedRouteMap(route: route, interactive: true)
                            .frame(height: 270)
                            .clipShape(.rect(cornerRadius: RunloopStyle.radius))
                        details
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                }
                .runloopCanvas()
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        NavigationLink {
                            RouteStartView(existing: route, editorVisible: $editorVisible, onSave: replace)
                        } label: {
                            Label("Modifica percorso", systemImage: "pencil")
                                .labelStyle(.iconOnly)
                        }
                        .disabled(isWorking)
                        .accessibilityIdentifier("route.edit")

                        Menu("Azioni percorso", systemImage: "ellipsis.circle") {
                            Button("Rinomina") { name = route.name; showsRename = true }
                            Button("Elimina", role: .destructive) { showsDelete = true }
                        }
                        .disabled(isWorking)
                    }
                }
            } else {
                ContentUnavailableView("Percorso non disponibile", systemImage: "map")
            }
        }
        .navigationTitle("Percorso")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rinomina percorso", isPresented: $showsRename) {
            TextField("Nome", text: $name)
            Button("Annulla", role: .cancel) {}
            Button("Salva") { Task { await rename() } }
        }
        .confirmationDialog("Eliminare il percorso?", isPresented: $showsDelete, titleVisibility: .visible) {
            Button("Elimina percorso", role: .destructive) { Task { await delete() } }
            Button("Annulla", role: .cancel) {}
        }
    }

    private var details: some View {
        let summary = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return VStack(alignment: .leading, spacing: 8) {
            Text("DISTANZA").font(RunloopType.readout).foregroundStyle(RunloopStyle.muted)
            summary {
                Text(routeDistanceText(route.distanceMeters)).font(RunloopType.metric)
                    .foregroundStyle(RunloopStyle.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if route.provider == "graphhopper" {
                    Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.caption2).foregroundStyle(RunloopStyle.muted)
                }
            }
            if let start = route.waypoints.first ?? route.geometry.coordinates.first {
                DepartureLabel(point: start).font(.subheadline).foregroundStyle(RunloopStyle.muted)
                    .padding(.bottom, 7)
            }
            Button("Inizia corsa", systemImage: "figure.run") {
                watchTransfer.runs.start(route: route.watchEnvelope, ownerID: access.session?.user.id)
            }
            .buttonStyle(RunloopButtonStyle())
            .accessibilityIdentifier("run.route")
            Button(watchStatus?.title ?? "Invia al Watch", systemImage: watchStatus == .received ? "checkmark" : "applewatch") {
                watchTransfer.send(route)
            }
            .buttonStyle(RunloopButtonStyle(kind: .secondary))
            GPXShareButton(name: route.name, points: route.geometry.coordinates.map { GPXPoint(coordinate: $0) },
                           creditsOpenStreetMap: route.provider == "graphhopper")
                .buttonStyle(RunloopButtonStyle(kind: .secondary, compact: true))
            if isWorking { ProgressView() }
            if let message { Text(message).font(.subheadline).foregroundStyle(RunloopStyle.danger) }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RunloopStyle.canvas)
        .animation(reduceMotion ? nil : RunloopMotion.status, value: watchStatus)
        .sensoryFeedback(.success, trigger: watchStatus) { _, current in current == .received }
    }

    private func replace(_ updated: SavedRoute) {
        guard updated.ownerID == access.session?.user.id else { return }
        route = updated
        onChange(updated)
    }

    private func rename() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { message = "Scegli un nome per il percorso."; return }
        guard let client = access.client, route.ownerID == access.session?.user.id else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do { replace(try await RouteLibraryService(client: client).rename(route, to: trimmed)) }
        catch { message = RouteLibraryService.message(for: error) }
    }

    private func delete() async {
        guard let client = access.client, route.ownerID == access.session?.user.id else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            try await RouteLibraryService(client: client).delete(route)
            onDelete(route.id)
            dismiss()
        } catch { message = RouteLibraryService.message(for: error) }
    }
}


private struct DepartureLabel: View {
    let point: RouteCoordinate
    @State private var address: String?
    @State private var resolvedPoint: RouteCoordinate?

    var body: some View {
        let fallback = point.latitude.formatted(.number.precision(.fractionLength(4))) + "°, " +
            point.longitude.formatted(.number.precision(.fractionLength(4))) + "°"
        Text("Partenza · " + ((resolvedPoint == point ? address : nil) ?? fallback))
            .task(id: point) {
                let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
                guard let request = MKReverseGeocodingRequest(location: location) else { return }
                let item = try? await request.mapItems.first
                guard !Task.isCancelled else { return }
                address = item?.address?.shortAddress
                resolvedPoint = point
            }
    }
}

private struct SavedRouteMap: View {
    let route: SavedRoute
    let interactive: Bool
    @Environment(\.runloopAccent) private var accent

    var body: some View {
        Map(initialPosition: .rect(routeMapRect(route.geometry.coordinates)),
            interactionModes: interactive ? .all : []) {
            MapPolyline(coordinates: route.geometry.coordinates.map(\.location))
                .stroke(RunloopStyle.canvas, lineWidth: 7)
            MapPolyline(coordinates: route.geometry.coordinates.map(\.location))
                .stroke(accent, lineWidth: 3.5)
            if let start = route.geometry.coordinates.first {
                Annotation("Partenza", coordinate: start.location) {
                    Circle().fill(accent).frame(width: 10, height: 10)
                        .overlay { Circle().strokeBorder(RunloopStyle.canvas, lineWidth: 2) }
                }.annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .id(route.revision)
    }
}
