import MapKit
import RunloopCore
import SwiftUI

@main
struct RunloopApp: App {
    @State private var inbox = WatchRouteInbox()
    @State private var workout = WatchWorkout()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if workout.isPresented {
                    WatchWorkoutView(workout: workout)
                } else {
                    library
                }
            }
            .preferredColorScheme(.dark)
            .tint(RunloopStyle.accent)
            .onChange(of: workout.phase) { _, phase in
                if phase == .saved { inbox.syncWorkouts() }
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
                        workout.start(route: nil, ownerID: inbox.currentOwner)
                    }
                    .buttonStyle(RunloopButtonStyle())
                    .disabled(workout.isPresented)

                    if inbox.workouts.pendingCount > 0 {
                        Button(inbox.workouts.needsRetry ? "Riprova invio corse" : "Corse in attesa di invio", systemImage: "arrow.trianglehead.clockwise") {
                            inbox.syncWorkouts()
                        }
                        .buttonStyle(RunloopButtonStyle(kind: .secondary))
                    }

                    Text("Percorsi")
                        .font(.subheadline.weight(.heavy))
                        .accessibilityAddTraits(.isHeader)
                    if inbox.readFailed {
                        Text("Impossibile leggere i percorsi.")
                            .font(.footnote).foregroundStyle(RunloopStyle.muted)
                    } else if inbox.routes.isEmpty {
                        Text("Invia un percorso dall’iPhone.")
                            .font(.footnote).foregroundStyle(RunloopStyle.muted)
                    }
                    ForEach(inbox.routes, id: \.entityID) { route in
                        NavigationLink {
                            if let latest = inbox.routes.first(where: { $0.entityID == route.entityID }) {
                                WatchRouteDetail(route: latest) {
                                    workout.start(route: latest, ownerID: inbox.currentOwner)
                                }
                            } else {
                                ContentUnavailableView("Percorso non disponibile", systemImage: "map")
                            }
                        } label: {
                            HStack(spacing: 8) {
                                RunloopTrace(coordinates: route.payload.geometry.coordinates, lineWidth: 2)
                                    .frame(width: 26, height: 38)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(route.payload.name).font(.footnote.weight(.bold))
                                    Text(watchDistance(route.payload.distanceMeters))
                                        .font(.caption2).monospacedDigit().foregroundStyle(RunloopStyle.muted)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                            }
                            .padding(9)
                            .frame(minHeight: 44)
                            .foregroundStyle(RunloopStyle.text)
                            .runloopPanel()
                        }
                        .buttonStyle(RunloopPressStyle())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .runloopCanvas()
            .navigationTitle("Runloop")
        }
    }
}

private struct WatchRouteDetail: View {
    let route: SyncEnvelope<RouteTransfer>
    let start: () -> Void
    @State private var showsMap = false

    private var locations: [CLLocationCoordinate2D] {
        route.payload.geometry.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(route.payload.name).font(.headline.weight(.heavy))
                Text(watchDistance(route.payload.distanceMeters))
                    .font(.title2.weight(.black)).monospacedDigit()
                    .foregroundStyle(RunloopStyle.accent)

                if showsMap {
                    Map(initialPosition: .rect(mapRect), interactionModes: []) {
                        MapPolyline(coordinates: locations).stroke(RunloopStyle.accent, lineWidth: 3)
                    }
                    .mapStyle(.standard(emphasis: .muted))
                    .frame(height: 86)
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
                Button(showsMap ? "Mostra traccia" : "Apri mappa", systemImage: showsMap ? "point.topleft.down.to.point.bottomright.curvepath" : "map") {
                    showsMap.toggle()
                }
                .buttonStyle(RunloopButtonStyle(kind: .secondary))
                .sensoryFeedback(.selection, trigger: showsMap)
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

func watchDistance(_ meters: Double) -> String {
    Measurement(value: meters / 1000, unit: UnitLength.kilometers)
        .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                numberFormatStyle: .number.precision(.fractionLength(0...2))))
}
