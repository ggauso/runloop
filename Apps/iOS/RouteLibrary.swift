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
    @State private var routes: [SavedRoute] = []
    @State private var snapshotOwner: UUID?
    @State private var isLoading = false
    @State private var message: String?
    @State private var revision = 0
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 49.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("RUNLOOP", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.caption.weight(.heavy)).tracking(2.8)
                        .foregroundStyle(RunloopStyle.accent)
                    Text("I miei percorsi")
                        .font(.system(size: titleSize, weight: .black)).tracking(-2)
                        .accessibilityAddTraits(.isHeader)
                }

                NavigationLink {
                    RouteStartView(onSave: replace)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                        Text("Nuovo percorso")
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right").font(.caption.weight(.heavy))
                    }
                    .padding(.horizontal, 8)
                }
                .buttonStyle(RunloopButtonStyle())
                .accessibilityIdentifier("library.newRoute")

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
                        ContentUnavailableView("Nessun percorso salvato", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    if let message {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message).font(.footnote).foregroundStyle(RunloopStyle.muted)
                            Button("Riprova") { Task { await refresh() } }
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
        .refreshable { await refresh() }
    }

    private func routeLink(_ route: SavedRoute, featured: Bool) -> some View {
        NavigationLink {
            SavedRouteDetail(route: route, onChange: replace, onDelete: remove)
        } label: {
            if featured {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("PERCORSO PIÙ RECENTE")
                            .font(.caption2.weight(.heavy)).tracking(1.7)
                            .foregroundStyle(RunloopStyle.muted)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.subheadline.weight(.bold))
                    }
                    .padding(16)
                    RunloopTrace(coordinates: route.geometry.coordinates, showsGrid: true, lineWidth: 3.5)
                        .frame(height: 137)
                        .background(RunloopStyle.canvas.opacity(0.6))
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(route.name).font(.headline)
                        Spacer(minLength: 0)
                        Text(routeDistanceText(route.distanceMeters)).font(.title3.weight(.heavy)).monospacedDigit()
                    }
                    .padding(16)
                }
                .foregroundStyle(RunloopStyle.text)
                .clipShape(.rect(cornerRadius: RunloopStyle.radius))
                .runloopPanel()
            } else {
                HStack(spacing: 14) {
                    RunloopTrace(coordinates: route.geometry.coordinates, lineWidth: 2)
                        .frame(width: 48, height: 44)
                        .runloopPanel()
                    Text(route.name).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Text(routeDistanceText(route.distanceMeters)).font(.footnote).monospacedDigit()
                        .foregroundStyle(RunloopStyle.muted)
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
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
                    MapPolyline(coordinates: route.geometry.coordinates.map(\.location)).stroke(RunloopStyle.accent, lineWidth: 4)
                    if let start = route.geometry.coordinates.first {
                        Marker("Partenza", systemImage: "flag.fill", coordinate: start.location).tint(RunloopStyle.accent)
                    }
                }
                .mapStyle(.standard(emphasis: .muted))
                .id(route.revision)
                .safeAreaInset(edge: .bottom) { details }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Azioni percorso", systemImage: "ellipsis.circle") {
                            NavigationLink("Modifica percorso") {
                                RouteStartView(existing: route, onSave: replace)
                            }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(routeDistanceText(route.distanceMeters)).font(.system(.largeTitle, weight: .black)).monospacedDigit()
                Spacer(minLength: 6)
                if route.provider == "graphhopper" {
                    Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.caption2).foregroundStyle(RunloopStyle.muted)
                }
            }
            Button("Invia al Watch", systemImage: "applewatch") { watchTransfer.send(route) }
                .buttonStyle(RunloopButtonStyle())
            if let watchStatus {
                Label(watchStatus.title, systemImage: watchStatus == .received ? "checkmark.circle.fill" : watchStatus == .failed ? "exclamationmark.circle" : "arrow.trianglehead.clockwise")
                    .font(.footnote)
                    .foregroundStyle(watchStatus == .received ? RunloopStyle.accent : RunloopStyle.muted)
                    .contentTransition(.opacity)
            }
            GPXShareButton(name: route.name, points: route.geometry.coordinates.map { GPXPoint(coordinate: $0) },
                           creditsOpenStreetMap: route.provider == "graphhopper")
            if isWorking { ProgressView() }
            if let message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RunloopStyle.canvas)
        .overlay(alignment: .top) { Divider().overlay(RunloopStyle.border) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: watchStatus)
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

func routeDistanceText(_ meters: Double) -> String {
    Measurement(value: meters / 1000, unit: UnitLength.kilometers)
        .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                numberFormatStyle: .number.precision(.fractionLength(0...2))))
}

func routeMapRect(_ coordinates: [RouteCoordinate]) -> MKMapRect {
    let rect = MKPolyline(coordinates: coordinates.map(\.location), count: coordinates.count).boundingMapRect
    return rect.insetBy(dx: -max(240, rect.width * 0.15), dy: -max(240, rect.height * 0.15))
}
