import SwiftUI

@main
struct RunloopApp: App {
    @State private var access = AccountAccess()
    @State private var watchTransfer = PhoneWatchTransfer()
    @State private var workoutCloud = WorkoutCloudSync()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Percorsi", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                    NavigationStack { RouteLibraryView() }
                }
                Tab("Allenamenti", systemImage: "figure.run") {
                    NavigationStack { WorkoutHistoryView() }
                }
                Tab("Account", systemImage: "person.crop.circle") {
                    NavigationStack { AccountView() }
                }
            }
            .preferredColorScheme(.dark)
            .tint(RunloopStyle.accent)
            .environment(access)
            .environment(watchTransfer)
            .environment(workoutCloud)
            .onChange(of: access.isRestoring, initial: true) { _, restoring in
                if !restoring { configureWorkoutOwner(access.session?.user.id) }
            }
            .onChange(of: access.session?.user.id) { _, owner in
                if !access.isRestoring { configureWorkoutOwner(owner) }
            }
            .onChange(of: watchTransfer.workouts.map(\.id)) { _, _ in synchronizeWorkouts() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { synchronizeWorkouts() } }
            .task { await access.observeSession() }
            .task { await workoutCloud.monitorConnectivity(onReconnect: synchronizeWorkouts) }
        }
    }

    private func configureWorkoutOwner(_ owner: UUID?) {
        workoutCloud.configure(owner: owner)
        watchTransfer.setOwner(owner)
        synchronizeWorkouts()
    }

    private func synchronizeWorkouts() {
        guard !access.isRestoring else { return }
        workoutCloud.synchronize(watchTransfer.workouts, client: access.client)
    }
}
