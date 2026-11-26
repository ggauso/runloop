import SwiftUI
import UIKit

@main
struct RunloopApp: App {
    @State private var access = AccountAccess()
    @State private var watchTransfer = PhoneWatchTransfer()
    @State private var workoutCloud = WorkoutCloudSync()
    @State private var tab = RunloopTab.routes
    @State private var keyboardVisible = false
    @AppStorage(RunloopAccent.storageKey) private var accentChoice = RunloopAccent.defaultChoice
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                TabView(selection: $tab) {
                    Tab("Percorsi", systemImage: RunloopTab.routes.icon, value: .routes) {
                        NavigationStack { RouteLibraryView() }.toolbarVisibility(.hidden, for: .tabBar)
                    }
                    Tab("Allenamenti", systemImage: RunloopTab.workouts.icon, value: .workouts) {
                        NavigationStack { WorkoutHistoryView() }.toolbarVisibility(.hidden, for: .tabBar)
                    }
                    Tab("Account", systemImage: RunloopTab.account.icon, value: .account) {
                        NavigationStack { AccountView() }.toolbarVisibility(.hidden, for: .tabBar)
                    }
                }
                if !keyboardVisible { RunloopTabBar(selection: $tab) }
            }
            .accessibilityHidden(watchTransfer.runs.isPresented)
            .allowsHitTesting(!watchTransfer.runs.isPresented)
            .overlay {
                if watchTransfer.runs.isPresented {
                    RunSessionScreen(runs: watchTransfer.runs)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RunloopStyle.canvas.ignoresSafeArea())
                }
            }
            .background(RunloopStyle.canvas.ignoresSafeArea())
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
            .preferredColorScheme(.dark)
            .modifier(RequestLocationPermissionOnLaunch())
            .tint(accentChoice.color)
            .environment(\.runloopAccent, accentChoice.color)
            .environment(access)
            .environment(watchTransfer)
            .environment(workoutCloud)
            .task(id: scenePhase) {
                if scenePhase == .active { await watchTransfer.runs.monitor() }
            }
            .onChange(of: watchTransfer.runs.local.phase) { _, phase in
                if phase == .discarded { watchTransfer.runs.rememberCompletion() }
                if phase == .saved {
                    watchTransfer.runs.rememberCompletion()
                    watchTransfer.refreshWorkouts()
                }
            }
            .onChange(of: recent, initial: true) { _, list in
                if !access.isRestoring { watchTransfer.setRecent(list, owner: access.session?.user.id) }
            }
            .onChange(of: access.isRestoring, initial: true) { _, restoring in
                watchTransfer.routeAccount = access
                if !restoring { configureWorkoutOwner(access.session?.user.id) }
            }
            .onChange(of: access.session?.user.id) { _, owner in
                if !access.isRestoring { configureWorkoutOwner(owner) }
            }
            .onChange(of: accentChoice, initial: true) { _, choice in watchTransfer.setAccent(choice) }
            .onChange(of: watchTransfer.workouts.map(\.id)) { _, _ in synchronizeWorkouts() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { synchronizeWorkouts() } }
            .task { await access.observeSession() }
            .task { await workoutCloud.monitorConnectivity(onReconnect: synchronizeWorkouts) }
        }
    }

    private var recent: [RunBrief] {
        workoutCloud.visible(watchTransfer.workouts).prefix(20).map(RunBrief.init)
    }

    private func configureWorkoutOwner(_ owner: UUID?) {
        workoutCloud.configure(owner: owner)
        watchTransfer.setOwner(owner)
        watchTransfer.setRecent(recent, owner: owner)
        synchronizeWorkouts()
    }

    private func synchronizeWorkouts() {
        guard !access.isRestoring else { return }
        workoutCloud.synchronize(watchTransfer.workouts, client: access.client)
    }
}

private enum RunloopTab: CaseIterable {
    case routes, workouts, account

    var title: LocalizedStringKey {
        switch self {
        case .routes: "Percorsi"
        case .workouts: "Allenamenti"
        case .account: "Account"
        }
    }

    var icon: String {
        switch self {
        case .routes: "point.topleft.down.to.point.bottomright.curvepath"
        case .workouts: "figure.run"
        case .account: "person.crop.circle"
        }
    }
}

private struct RunloopTabBar: View {
    @Binding var selection: RunloopTab
    @Environment(\.runloopAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 1) {
            ForEach(RunloopTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon).font(.system(size: 18, weight: .medium))
                        Text(tab.title).font(.caption2.weight(.semibold))
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 5)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(selection == tab ? accent : RunloopStyle.muted)
                    .overlay(alignment: .top) {
                        if selection == tab {
                            Capsule().fill(accent).frame(width: 24, height: 2)
                                .matchedGeometryEffect(id: "active-tab", in: indicator)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(RunloopPressStyle())
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .frame(maxWidth: 620)
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
        .background(RunloopStyle.canvas)
        .overlay(alignment: .top) { Divider().overlay(RunloopStyle.border) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Schede")
        .accessibilityAddTraits(.isTabBar)
        .animation(reduceMotion ? nil : RunloopMotion.selection, value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
