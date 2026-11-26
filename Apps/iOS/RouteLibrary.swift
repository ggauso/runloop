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
    @Environment(AccountAccess.self) private var access
    @Environment(PhoneWatchTransfer.self) private var watchTransfer
    @State private var routes: [SavedRoute] = []
    @State private var snapshotOwner: UUID?
    @State private var isLoading = false
    @State private var message: String?
    @State private var revision = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        libraryTitle.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 4)
                        newRouteLink.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        libraryTitle
                        newRouteLink
                    }
                }

                Button("Corsa libera", systemImage: "figure.run") {
                    watchTransfer.runs.start(route: nil, ownerID: access.session?.user.id)
                }
                .buttonStyle(RunloopButtonStyle())
                .accessibilityIdentifier("run.free")

                if let owner = access.session?.user.id {
                    if let latest = owner == snapshotOwner ? routes.first : nil {
                        routeLink(latest, featured: true)
                        if routes.count > 1 {
                            VStack(spacing: 0) {
                                ForEach(routes.dropFirst()) { route in
                                    routeLink(route, featured: false)
                                    if route.id != routes.last?.id { Divider().overlay(RunloopStyle.border) }
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

    private var libraryTitle: some View {
        Text("Percorsi")
            .font(RunloopType.screenTitle)
            .accessibilityAddTraits(.isHeader)
    }

    private var newRouteLink: some View {
        NavigationLink {
            RouteStartView(onSave: replace)
        } label: {
            Label("Nuovo percorso", systemImage: "plus")
        }
        .buttonStyle(RunloopButtonStyle(compact: true))
        .accessibilityIdentifier("library.newRoute")
    }

    private func routeLink(_ route: SavedRoute, featured: Bool) -> some View {
        NavigationLink {
            SavedRouteDetail(route: route, onChange: replace, onDelete: remove)
        } label: {
            if featured {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ultimo percorso")
                        .font(RunloopType.readout)
                        .foregroundStyle(RunloopStyle.muted)
                    RunloopTrace(coordinates: route.geometry.coordinates, showsGrid: true, lineWidth: 3.5)
                        .frame(height: 154)
                        .background(RunloopStyle.panel, in: .rect(cornerRadius: RunloopStyle.radius))
                        .clipShape(.rect(cornerRadius: RunloopStyle.radius))
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(route.name).font(RunloopType.sectionTitle)
                            Text(routeSummary(distance: route.distanceMeters, mode: route.mode))
                                .font(RunloopType.readout)
                                .foregroundStyle(RunloopStyle.muted)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(RunloopStyle.muted)
                    }
                    .padding(.bottom, 8)
                }
                .foregroundStyle(RunloopStyle.text)
                .contentShape(.rect)
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
                Map(initialPosition: .rect(routeMapRect(route.geometry.coordinates))) {
                    MapPolyline(coordinates: route.geometry.coordinates.map(\.location)).stroke(.black.opacity(0.8), lineWidth: 8)
                    MapPolyline(coordinates: route.geometry.coordinates.map(\.location)).stroke(accent, lineWidth: 4)
                    if let start = route.geometry.coordinates.first {
                        Annotation("Partenza", coordinate: start.location, anchor: .bottom) { RouteMapPin(index: 0) }
                    }
                }
                .mapStyle(.standard(emphasis: .muted))
                .id(route.revision)
                .safeAreaInset(edge: .bottom) { details }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(route.name)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        NavigationLink {
                            RouteStartView(existing: route, onSave: replace)
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
        .navigationTitle(route.ownerID == access.session?.user.id ? route.name : "Percorso")
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
        let actions = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 10))
        return VStack(alignment: .leading, spacing: 8) {
            summary {
                Text(routeDistanceText(route.distanceMeters)).font(RunloopType.metric)
                    .foregroundStyle(RunloopStyle.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if route.provider == "graphhopper" {
                    Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.caption2).foregroundStyle(RunloopStyle.muted)
                }
            }
            Button("Inizia corsa", systemImage: "figure.run") {
                watchTransfer.runs.start(route: route.watchEnvelope, ownerID: access.session?.user.id)
            }
            .buttonStyle(RunloopButtonStyle())
            .accessibilityIdentifier("run.route")
            actions {
                Button("Invia al Watch", systemImage: "applewatch") { watchTransfer.send(route) }
                    .buttonStyle(RunloopButtonStyle(kind: .secondary, compact: true))
                GPXShareButton(name: route.name, points: route.geometry.coordinates.map { GPXPoint(coordinate: $0) },
                               creditsOpenStreetMap: route.provider == "graphhopper")
                    .buttonStyle(RunloopButtonStyle(kind: .secondary, compact: true))
            }
            if let watchStatus {
                Label(watchStatus.title, systemImage: watchStatus == .received ? "checkmark.circle.fill" : watchStatus == .failed ? "exclamationmark.circle" : "arrow.trianglehead.clockwise")
                    .font(.footnote)
                    .foregroundStyle(watchStatus == .received ? accent : watchStatus == .failed ? RunloopStyle.danger : RunloopStyle.muted)
                    .contentTransition(.opacity)
            }
            if isWorking { ProgressView() }
            if let message { Text(message).font(.subheadline).foregroundStyle(RunloopStyle.danger) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RunloopStyle.canvas)
        .overlay(alignment: .top) { Divider().overlay(RunloopStyle.border) }
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
