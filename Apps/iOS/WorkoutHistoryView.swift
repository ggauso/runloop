import MapKit
import RunloopCore
import Supabase
import SwiftUI

struct WorkoutHistoryView: View {
    @Environment(AccountAccess.self) private var access
    @Environment(PhoneWatchTransfer.self) private var watch
    @Environment(WorkoutCloudSync.self) private var sync
    @Environment(\.runloopAccent) private var accent
    @State private var cloudRows: [CloudWorkout] = []
    @State private var cloudOwner: UUID?
    @State private var cloudFailed = false
    @State private var hasMore = false
    @State private var isLoading = false

    private var entries: [WorkoutHistoryEntry] {
        let local = sync.visible(watch.workouts).map(WorkoutHistoryEntry.init)
        let localIDs = Set(local.map(\.id))
        let cloud = cloudOwner == access.session?.user.id
            ? cloudRows.filter { !localIDs.contains($0.id) }.compactMap(WorkoutHistoryEntry.init)
            : []
        return (local + cloud).sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        List {
            RunloopHeading(context: "Runloop  /  Storico", title: "Allenamenti")
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            if let latest = entries.first {
                NavigationLink {
                    detail(latest)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ULTIMA CORSA").font(RunloopType.readout).foregroundStyle(RunloopStyle.muted)
                        Text(routeDistanceText(latest.distanceMeters))
                            .font(RunloopType.display(size: 84, relativeTo: .largeTitle)).foregroundStyle(accent)
                            .lineLimit(1).minimumScaleFactor(0.55)
                        Text(latest.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Text("Tempo attivo " + Duration.seconds(latest.duration).formatted(.time(pattern: .minuteSecond)))
                            .font(RunloopType.readout).foregroundStyle(RunloopStyle.muted)
                        if let local = latest.local, !local.points.isEmpty {
                            RunLiveMap(planned: [], trail: local.points.map(\.coordinate))
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }.padding(.vertical, 8)
                }
                .accessibilityIdentifier("history.workout." + latest.id.uuidString)
                .listRowBackground(Color.clear)
            }
            Button("Corsa libera", systemImage: "figure.run") {
                watch.runs.start(route: nil, ownerID: access.session?.user.id)
            }
            .buttonStyle(RunloopButtonStyle())
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("run.free")
            if entries.isEmpty {
                ContentUnavailableView(watch.workoutReadFailed ? "Allenamenti non disponibili" : "Nessun allenamento",
                                       systemImage: "figure.run")
                    .listRowBackground(Color.clear)
            }
            ForEach(entries.dropFirst()) { entry in
                NavigationLink {
                    detail(entry)
                } label: {
                    HStack(spacing: 12) {
                        Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 4)
                        Text(routeDistanceText(entry.distanceMeters))
                            .font(RunloopType.readout).foregroundStyle(RunloopStyle.muted)
                    }.padding(.vertical, 6)
                }
                .accessibilityIdentifier("history.workout." + entry.id.uuidString)
                .listRowBackground(Color.clear).listRowSeparatorTint(RunloopStyle.border)
            }
            if cloudFailed {
                Section {
                    Text("Cloud non disponibile. Puoi consultare le corse salvate qui.").foregroundStyle(RunloopStyle.muted)
                    Button("Riprova") { Task { await loadCloud() } }
                }
                .listRowBackground(RunloopStyle.panel)
            } else if hasMore {
                Button("Mostra altri allenamenti") { Task { await loadCloud(addPage: true) } }
                    .disabled(isLoading)
            }
        }
        .scrollContentBackground(.hidden)
        .runloopCanvas()
        .navigationTitle("Allenamenti")
        .toolbar(.hidden, for: .navigationBar)
        .task(id: access.session?.user.id) { await loadCloud() }
        .refreshable { await loadCloud() }
    }

    private func detail(_ entry: WorkoutHistoryEntry) -> some View {
        WorkoutDetailView(entry: entry) { cloudRows.removeAll { $0.id == entry.id } }
    }

    private func loadCloud(addPage: Bool = false) async {
        let owner = access.session?.user.id
        if cloudOwner != owner {
            cloudRows = []
            hasMore = false
            cloudFailed = false
        }
        cloudOwner = owner
        guard let owner, let client = access.client else { return }
        isLoading = true
        defer { if cloudOwner == owner { isLoading = false } }
        do {
            let offset = addPage ? cloudRows.count : 0
            let rows = try await WorkoutHistoryService(client: client).list(offset: offset)
            guard !Task.isCancelled, owner == access.session?.user.id else { return }
            cloudRows = addPage ? cloudRows + rows : rows
            hasMore = rows.count == WorkoutHistoryService.pageSize
            cloudFailed = false
        } catch {
            guard !Task.isCancelled, owner == access.session?.user.id else { return }
            cloudFailed = true
        }
    }
}

private struct WorkoutDetailView: View {
    @Environment(\.runloopAccent) private var accent
    @Environment(AccountAccess.self) private var access
    @Environment(PhoneWatchTransfer.self) private var watch
    @Environment(WorkoutCloudSync.self) private var sync
    @Environment(\.dismiss) private var dismiss
    let entry: WorkoutHistoryEntry
    let onDelete: () -> Void
    @State private var remotePoints: [GPXPoint] = []
    @State private var remotePlan: RouteGeometry?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var confirmsDeletion = false
    @State private var isDeleting = false
    @State private var deletionFailed = false
    @State private var confirmsAdoption = false
    @State private var adoptingOwner: UUID?

    private var canRead: Bool {
        if let local = entry.local { return sync.visible(watch.workouts).contains(where: { $0.id == local.id }) }
        return entry.ownerID != nil && entry.ownerID == access.session?.user.id
    }

    private var points: [GPXPoint] {
        entry.local?.points.map { GPXPoint(coordinate: $0.coordinate, recordedAt: $0.recordedAt) } ?? remotePoints
    }
    private var coordinates: [RouteCoordinate] { points.map(\.coordinate) }
    private var plan: RouteGeometry? { entry.local?.plannedRoute ?? remotePlan }
    private var mapCoordinates: [RouteCoordinate] { coordinates + (plan?.coordinates ?? []) }

    var body: some View {
        Group {
            if canRead {
                List {
                    Section {
                        workoutSummary
                    }
                    .listRowBackground(RunloopStyle.panel)
                    Section("Traccia") {
                        if !mapCoordinates.isEmpty {
                            Map(initialPosition: .rect(routeMapRect(mapCoordinates)), interactionModes: []) {
                                if let plan {
                                    MapPolyline(coordinates: plan.coordinates.map(\.location))
                                        .stroke(RunloopStyle.muted, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [5, 5]))
                                }
                                if coordinates.count > 1 {
                                    MapPolyline(coordinates: coordinates.map(\.location)).stroke(.black.opacity(0.9), lineWidth: 8)
                                    MapPolyline(coordinates: coordinates.map(\.location)).stroke(accent, lineWidth: 4)
                                } else if let coordinate = coordinates.first {
                                    Marker("Punto registrato", coordinate: coordinate.location).tint(accent)
                                }
                            }
                            .mapStyle(.standard(emphasis: .muted))
                            .frame(height: 260)
                            .clipShape(.rect(cornerRadius: 12))
                            .id(mapCoordinates)
                            .accessibilityLabel("Mappa dell’allenamento")
                            if !coordinates.isEmpty { Label("Traccia registrata", systemImage: "minus").foregroundStyle(accent) }
                            if plan != nil {
                                Label("Percorso pianificato", systemImage: "ellipsis").foregroundStyle(RunloopStyle.muted)
                                Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                                    .font(.caption)
                            }
                        } else if isLoading {
                            ProgressView("Caricamento traccia…")
                        } else if loadFailed {
                            Text("Traccia non disponibile. Riprova con una connessione.").foregroundStyle(RunloopStyle.muted)
                            Button("Riprova") { Task { await loadTrace() } }
                        } else {
                            Text("Nessuna traccia GPS registrata.").foregroundStyle(RunloopStyle.muted)
                        }
                        if !points.isEmpty {
                            GPXShareButton(name: "Corsa Runloop \(entry.startedAt.formatted(.iso8601.year().month().day()))", points: points)
                        }
                    }
                    .listRowBackground(RunloopStyle.panel)
                    if let workout = entry.local, sync.canAdopt(workout) {
                        Button("Carica sul mio account") {
                            adoptingOwner = access.session?.user.id
                            confirmsAdoption = adoptingOwner != nil
                        }
                    }
                    Section("Sincronizzazione") {
                        LabeledContent("Stato", value: syncStatus)
                        if let workout = entry.local, sync.stage(for: workout) == .failed {
                            Button("Riprova sincronizzazione") { sync.synchronize([workout], client: access.client) }
                        }
                    }
                    .listRowBackground(RunloopStyle.panel)
                    Section {
                        Button("Elimina allenamento", role: .destructive) { confirmsDeletion = true }
                        if isDeleting { ProgressView("Eliminazione…") }
                        if deletionFailed { Text("Impossibile eliminare la corsa. Riprova quando sei online.") }
                    }
                    .listRowBackground(RunloopStyle.panel)
                }
                .scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView("Allenamento non disponibile", systemImage: "figure.run")
            }
        }
        .runloopCanvas()
        .navigationTitle("Allenamento")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: access.session?.user.id) { await loadTrace() }
        .onChange(of: access.session?.user.id) { _, _ in
            confirmsAdoption = false
            adoptingOwner = nil
        }
        .alert("Caricare questa corsa?", isPresented: $confirmsAdoption, presenting: entry.local) { workout in
            Button("Carica sul mio account") {
                guard let adoptingOwner, adoptingOwner == access.session?.user.id else { return }
                sync.adopt(workout, client: access.client)
            }
            Button("Lascia sul dispositivo", role: .cancel) {}
        } message: { _ in
            Text("Runloop assocerà questa corsa e la sua eventuale traccia GPS all’account con cui hai effettuato l’accesso.")
        }
        .confirmationDialog("Eliminare questo allenamento?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Elimina da Runloop", role: .destructive) { Task { await delete() } }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Runloop rimuoverà la corsa e la sua traccia. La copia nell’app Salute si gestisce da Salute.")
        }
        .disabled(isDeleting)
    }

    private var workoutSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline).foregroundStyle(RunloopStyle.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(routeDistanceText(entry.distanceMeters))
                    .font(RunloopType.metric)
                    .foregroundStyle(accent)
                Text("Distanza").font(.footnote).foregroundStyle(RunloopStyle.muted)
            }
            .accessibilityElement(children: .combine)
            Divider().overlay(RunloopStyle.border)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { workoutMetrics }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 10) { workoutMetrics }
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private var workoutMetrics: some View {
        metric("Durata attiva", Duration.seconds(entry.duration).formatted(.time(pattern: .hourMinuteSecond)))
            .accessibilityIdentifier("history.duration")
        metric("Passo medio", entry.pace.map(paceText) ?? "—")
        if let heartRate = entry.heartRate {
            metric("FC media", "\(heartRate.formatted(.number.precision(.fractionLength(0)))) bpm")
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(RunloopType.compactMetric)
            Text(title).font(.caption).foregroundStyle(RunloopStyle.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private var syncStatus: String {
        guard let workout = entry.local else { return "Sincronizzato" }
        switch sync.stage(for: workout) {
        case .queued: return "In coda"
        case .synced: return "Sincronizzato"
        case .failed: return "Errore"
        case nil: return "Locale"
        }
    }

    private func delete() async {
        guard canRead, !isDeleting else { return }
        deletionFailed = false
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await sync.remove(id: entry.id, local: entry.local, remoteOwner: entry.ownerID, watch: watch, client: access.client)
            onDelete()
            dismiss()
        } catch {
            deletionFailed = true
        }
    }

    private func paceText(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        return "\(rounded / 60):\(String(format: "%02d", rounded % 60)) /km"
    }

    private func loadTrace() async {
        guard entry.local == nil, canRead, let client = access.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let service = WorkoutHistoryService(client: client)
            let points = try await service.points(for: entry.id)
            guard !Task.isCancelled, canRead else { return }
            remotePoints = points
            loadFailed = false
            if let routeID = entry.routeID {
                let plan = try? await service.plan(for: routeID)
                guard !Task.isCancelled, canRead else { return }
                remotePlan = plan
            }
        } catch {
            guard !Task.isCancelled, canRead else { return }
            loadFailed = true
        }
    }
}

private struct WorkoutHistoryEntry: Identifiable {
    let id: UUID
    let ownerID: UUID?
    let routeID: UUID?
    let startedAt: Date
    let duration: Double
    let distanceMeters: Double
    let pace: Double?
    let heartRate: Double?
    let local: RecordedWorkout?

    init(_ workout: RecordedWorkout) {
        id = workout.id
        ownerID = workout.ownerID
        routeID = workout.routeID
        startedAt = workout.startedAt
        duration = workout.activeDurationSeconds
        distanceMeters = workout.distanceMeters
        pace = workout.averagePaceSecondsPerKilometer
        heartRate = workout.averageHeartRateBPM
        local = workout
    }

    init?(_ workout: CloudWorkout) {
        guard let date = workoutDate(workout.started_at) else { return nil }
        id = workout.id
        ownerID = workout.owner_id
        routeID = workout.route_id
        startedAt = date
        duration = Double(workout.active_duration_s)
        distanceMeters = workout.distance_m
        pace = workout.avg_pace_s_per_km
        heartRate = workout.avg_heart_rate_bpm
        local = nil
    }
}

private func workoutDate(_ value: String) -> Date? {
    (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
        ?? (try? Date.ISO8601FormatStyle().parse(value))
}

private struct CloudWorkout: Decodable {
    let id: UUID
    let owner_id: UUID
    let route_id: UUID?
    let started_at: String
    let active_duration_s: Int
    let distance_m: Double
    let avg_pace_s_per_km: Double?
    let avg_heart_rate_bpm: Double?
}

private struct WorkoutHistoryService {
    static let pageSize = 100
    let client: SupabaseClient

    func list(offset: Int) async throws -> [CloudWorkout] {
        try await client.from("workouts")
            .select("id,owner_id,route_id,started_at,active_duration_s,distance_m,avg_pace_s_per_km,avg_heart_rate_bpm")
            .eq("upload_complete", value: true).order("started_at", ascending: false).order("id")
            .range(from: offset, to: offset + Self.pageSize - 1).execute().value
    }

    func points(for id: UUID) async throws -> [GPXPoint] {
        let size = 500
        var points: [GPXPoint] = []
        while true {
            try Task.checkCancellation()
            let batch: [CloudPoint] = try await client.from("workout_points").select("position,recorded_at")
                .eq("workout_id", value: id).order("sequence")
                .range(from: points.count, to: points.count + size - 1).execute().value
            points.append(contentsOf: batch.map { GPXPoint(coordinate: $0.position.coordinate, recordedAt: workoutDate($0.recorded_at)) })
            if batch.count < size { return points }
        }
    }

    func plan(for id: UUID) async throws -> RouteGeometry? {
        struct Plan: Decodable { let geometry: RouteGeometry }
        let rows: [Plan] = try await client.from("routes").select("geometry").eq("id", value: id).limit(1).execute().value
        return rows.first?.geometry
    }

    private struct CloudPoint: Decodable {
        let position: Position
        let recorded_at: String

        struct Position: Decodable {
            let coordinate: RouteCoordinate
            private enum CodingKeys: String, CodingKey { case type, coordinates }

            init(from decoder: any Decoder) throws {
                let row = try decoder.container(keyedBy: CodingKeys.self)
                let values = try row.decode([Double].self, forKey: .coordinates)
                guard try row.decode(String.self, forKey: .type) == "Point", values.count == 2 else {
                    throw DecodingError.dataCorruptedError(forKey: .coordinates, in: row, debugDescription: "Expected a GeoJSON Point")
                }
                coordinate = RouteCoordinate(latitude: values[1], longitude: values[0])
            }
        }
    }
}
