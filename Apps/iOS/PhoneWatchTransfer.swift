import Foundation
import Observation
import RunloopCore
@preconcurrency import WatchConnectivity

@MainActor
@Observable
final class PhoneWatchTransfer: NSObject, WCSessionDelegate {
    enum Delivery: String, Codable {
        case sending, waiting, received, failed

        var title: String {
            switch self {
            case .sending: "Invio in corso…"
            case .waiting: "In attesa di conferma dal Watch"
            case .received: "Disponibile sul Watch"
            case .failed: "Invio non riuscito. Puoi riprovare."
            }
        }
    }

    private struct Attempt: Codable {
        let receipt: RouteReceipt
        let name: String
        var delivery: Delivery
    }

    private static let storageKey = "runloop.watchRouteTransfers"
    private static let pendingDeletionKey = "runloop.watchWorkoutDeletions"
    private var attempts = [UUID: Attempt]()
    let runs = RunCompanion()
    private var recent: [RunBrief] = []
    private var ownerID: UUID?
    @ObservationIgnored weak var routeAccount: AccountAccess?
    private(set) var watchRouteRevision = 0
    private var accent = RunloopAccent.defaultChoice
    private(set) var hasAccountState = false
    private var ready = false
    private var session: WCSession?
    private var pendingDeletions: [WorkoutReceipt] = []
    private var sendingDeletions = Set<WorkoutReceipt>()
    private let workoutArchive = PhoneWorkoutArchive(
        root: URL.applicationSupportDirectory.appending(path: "Runloop/Workouts", directoryHint: .isDirectory)
    )
    private(set) var workouts: [RecordedWorkout] = []
    private(set) var workoutReadFailed = false

    override init() {
        super.init()
        refreshWorkouts()
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([UUID: Attempt].self, from: data) {
            attempts = saved
        }
        if let data = UserDefaults.standard.data(forKey: Self.pendingDeletionKey),
           let saved = try? JSONDecoder().decode([WorkoutReceipt].self, from: data) {
            pendingDeletions = saved
        }
        guard WCSession.isSupported() else { return }
        session = WCSession.default
        session?.delegate = self
        session?.activate()
    }

    func setOwner(_ ownerID: UUID?) {
        if self.ownerID != ownerID { recent = [] }
        self.ownerID = ownerID
        runs.setOwner(ownerID)
        hasAccountState = true
        refreshWorkouts()
        syncOwner()
    }

    func setRecent(_ list: [RunBrief], owner: UUID?) {
        guard owner == ownerID, recent != list else { return }
        recent = list
        syncOwner()
    }

    func setAccent(_ value: RunloopAccent) {
        guard value != accent else { return }
        accent = value
        syncOwner()
    }

    func refreshWorkouts() {
        do {
            workouts = try workoutArchive.workouts(for: ownerID)
            workoutReadFailed = false
        } catch {
            workouts = []
            workoutReadFailed = true
        }
    }

    func removeWorkout(id: UUID, originalOwner: UUID?) throws {
        let fromPhone = workouts.first { $0.id == id }?.source == .phone
        try workoutArchive.remove(id: id, originalOwner: originalOwner)
        refreshWorkouts()
        guard !fromPhone else { return }
        let receipt = WorkoutReceipt(workoutID: id, ownerID: originalOwner)
        if !pendingDeletions.contains(receipt) {
            pendingDeletions.append(receipt)
            savePendingDeletions()
        }
        flushDeletions()
    }

    private func savePendingDeletions() {
        if let data = try? JSONEncoder().encode(pendingDeletions) {
            UserDefaults.standard.set(data, forKey: Self.pendingDeletionKey)
        }
    }

    private func confirmDeletion(_ receipt: WorkoutReceipt) {
        sendingDeletions.remove(receipt)
        pendingDeletions.removeAll { $0 == receipt }
        savePendingDeletions()
    }

    private func flushDeletions() {
        guard let session, ready else { return }
        #if targetEnvironment(simulator)
        guard session.isReachable else { return }
        #else
        guard session.isPaired, session.isWatchAppInstalled else { return }
        #endif
        for receipt in pendingDeletions where !sendingDeletions.contains(receipt) {
            guard let data = try? JSONEncoder().encode(receipt) else { continue }
            sendingDeletions.insert(receipt)
            #if targetEnvironment(simulator)
            session.sendMessage([WorkoutTransfer.deletionKey: data]) { [weak self] reply in
                let removed = reply[WorkoutTransfer.deletionReceiptKey] as? Bool == true
                Task { @MainActor in
                    if removed { self?.confirmDeletion(receipt) }
                    else { self?.sendingDeletions.remove(receipt) }
                }
            } errorHandler: { [weak self] _ in
                Task { @MainActor in self?.sendingDeletions.remove(receipt) }
            }
            #else
            if !session.outstandingUserInfoTransfers.contains(where: { $0.userInfo[WorkoutTransfer.deletionKey] as? Data == data }) {
                session.transferUserInfo([WorkoutTransfer.deletionKey: data])
            }
            #endif
        }
    }

    private func receiveWorkout(_ data: Data) throws -> Data {
        let receipt = try workoutArchive.receive(data)
        refreshWorkouts()
        return try JSONEncoder().encode(receipt)
    }

    func status(for route: SavedRoute) -> Delivery? {
        guard let attempt = attempts[route.id], attempt.receipt.revision == route.revision,
              attempt.receipt.ownerID == route.ownerID, attempt.name == route.name else { return nil }
        return attempt.delivery
    }

    func send(_ route: SavedRoute) {
        guard ownerID == route.ownerID else { return }
        let envelope = route.watchEnvelope
        let receipt = RouteReceipt(ownerID: route.ownerID, routeID: route.id, revision: route.revision, createdAt: envelope.createdAt)
        guard let session, ready, syncOwner() else {
            record(Attempt(receipt: receipt, name: route.name, delivery: .failed))
            return
        }

        do {
            let data = try JSONEncoder().encode(envelope)
            guard data.count <= RouteTransferKeys.byteLimit else { throw CocoaError(.fileWriteOutOfSpace) }
            #if targetEnvironment(simulator)
            guard session.isReachable else { throw CocoaError(.featureUnsupported) }
            record(Attempt(receipt: receipt, name: route.name, delivery: .sending))
            session.sendMessageData(data) { [weak self] reply in
                let confirmation = try? JSONDecoder().decode(RouteReceipt.self, from: reply)
                Task { @MainActor in
                    self?.update(receipt, to: confirmation == receipt ? .received : .failed)
                }
            } errorHandler: { [weak self] _ in
                Task { @MainActor in self?.update(receipt, to: .failed) }
            }
            #else
            guard session.isPaired, session.isWatchAppInstalled else { throw CocoaError(.featureUnsupported) }
            let metadata = try JSONEncoder().encode(receipt)
            let staging = URL.applicationSupportDirectory.appending(path: "Runloop/WatchTransfers", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let file = staging.appending(path: UUID().uuidString + ".json")
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            record(Attempt(receipt: receipt, name: route.name, delivery: .sending))
            session.transferFile(file, metadata: [RouteTransferKeys.version: metadata])
            #endif
        } catch {
            record(Attempt(receipt: receipt, name: route.name, delivery: .failed))
        }
    }

    private func planRoute(_ data: Data) async -> WatchRouteReply {
        guard let request = try? WatchRouteMessage.decode(WatchRouteRequest.self, from: data), request.draft.isValid else {
            return .failure("Controlla i punti del percorso e riprova.")
        }
        guard let account = routeAccount, let client = account.client,
              request.ownerID == ownerID, request.ownerID == account.session?.user.id else {
            return .failure("Accedi a Runloop su iPhone e riprova.")
        }
        let draft = request.draft
        switch request.action {
        case .calculate(let seeds):
            let service = RoutingService(client: client)
            do {
                let previews: [RoutePreview]
                if draft.mode == .manual {
                    previews = [try await service.manual(waypoints: draft.waypoints)]
                } else if let start = draft.waypoints.first,
                          (2...RouteDraft.loopBatchSize).contains(seeds.count), Set(seeds).count == seeds.count,
                          seeds.allSatisfy({ (0...Int(Int32.max)).contains($0) }) {
                    previews = try await service.loopAlternatives(start: start,
                        waypoints: draft.mode == .waypointLoop ? draft.waypoints : nil,
                        targetDistanceMeters: draft.targetDistanceMeters, seeds: seeds)
                } else {
                    return .failure("Impossibile preparare la ricerca. Riprova.")
                }
                guard request.ownerID == account.session?.user.id else {
                    return .failure("Accedi a Runloop su iPhone e riprova.")
                }
                return .previews(previews)
            } catch {
                return .failure(RoutingService.message(for: error))
            }
        case .save(let id, let name, let preview):
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...80).contains(title.count), preview.distanceMeters.isFinite, preview.distanceMeters > 0,
                  preview.provider == "graphhopper", (2...25000).contains(preview.coordinates.count),
                  draft.mode == .manual || preview.coordinates.first == preview.coordinates.last else {
                return .failure("Controlla il nome e il percorso, poi riprova.")
            }
            let route = SavedRoute(id: id, ownerID: request.ownerID, name: title, mode: draft.mode,
                                   targetDistanceMeters: draft.mode == .roundTrip ? draft.targetDistanceMeters : nil,
                                   distanceMeters: preview.distanceMeters, waypoints: draft.waypoints,
                                   geometry: preview.geometry, provider: preview.provider, revision: 1)
            do {
                let stored = try await RouteLibraryService(client: client).saveFromWatch(route)
                guard stored.ownerID == account.session?.user.id else {
                    return .failure("Accedi a Runloop su iPhone e riprova.")
                }
                watchRouteRevision += 1
                return .saved(stored.watchEnvelope)
            } catch {
                return .failure(RouteLibraryService.message(for: error))
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping @Sendable ([String: Any]) -> Void) {
        if let data = message[RunCompanion.key] as? Data {
            Task { @MainActor in replyHandler([RunCompanion.key: await runs.respond(data)]) }
            return
        }
        guard let data = message[WatchRouteMessage.requestKey] as? Data else { replyHandler([:]); return }
        Task { @MainActor in
            let reply = await planRoute(data)
            let encoded: Data?
            if case .previews(let previews) = reply {
                encoded = previews.indices.reversed().lazy.compactMap { index in
                    try? WatchRouteMessage.encode(WatchRouteReply.previews(Array(previews.prefix(index + 1))))
                }.first
            } else {
                encoded = try? WatchRouteMessage.encode(reply)
            }
            let response = encoded ?? (try? WatchRouteMessage.encode(WatchRouteReply.failure("Percorso troppo grande per il Watch. Prova con una distanza più breve.")))
            replyHandler(response.map { [WatchRouteMessage.replyKey: $0] } ?? [:])
        }
    }

    @discardableResult
    private func syncOwner() -> Bool {
        guard ready, hasAccountState, let session else { return false }
        do {
            try session.updateApplicationContext([
                RouteTransferKeys.owner: ownerID?.uuidString ?? "",
                RunBrief.contextKey: try JSONEncoder().encode(recent),
                RunloopAccent.contextKey: accent.rawValue
            ])
            return true
        } catch {
            return false
        }
    }

    private func record(_ attempt: Attempt) {
        attempts[attempt.receipt.routeID] = attempt
        if let encoded = try? JSONEncoder().encode(attempts) {
            UserDefaults.standard.set(encoded, forKey: Self.storageKey)
        }
    }

    private func update(_ receipt: RouteReceipt, to delivery: Delivery) {
        guard var attempt = attempts[receipt.routeID], attempt.receipt == receipt, attempt.delivery != .received else { return }
        attempt.delivery = delivery
        record(attempt)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {
        let activated = activationState == .activated && error == nil
        Task { @MainActor in
            ready = activated
            syncOwner()
            flushDeletions()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in ready = false }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            ready = false
            self.session?.activate()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            syncOwner()
            flushDeletions()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable { Task { @MainActor in flushDeletions() } }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        guard let data = fileTransfer.file.metadata?[RouteTransferKeys.version] as? Data,
              let receipt = try? JSONDecoder().decode(RouteReceipt.self, from: data) else { return }
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        let delivered = error == nil
        Task { @MainActor in update(receipt, to: delivered ? .waiting : .failed) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let data = userInfo[WorkoutTransfer.deletionReceiptKey] as? Data,
           let receipt = try? JSONDecoder().decode(WorkoutReceipt.self, from: data) {
            Task { @MainActor in confirmDeletion(receipt) }
            return
        }
        guard let data = userInfo[RouteTransferKeys.receipt] as? Data,
              let receipt = try? JSONDecoder().decode(RouteReceipt.self, from: data) else { return }
        Task { @MainActor in update(receipt, to: .received) }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: (any Error)?) {
        guard let data = userInfoTransfer.userInfo[WorkoutTransfer.deletionKey] as? Data,
              let receipt = try? JSONDecoder().decode(WorkoutReceipt.self, from: data) else { return }
        Task { @MainActor in sendingDeletions.remove(receipt) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        #if !targetEnvironment(simulator)
        guard file.metadata?[WorkoutTransfer.metadataKey] is String,
              let values = try? file.fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= WorkoutTransfer.byteLimit,
              let data = try? Data(contentsOf: file.fileURL) else { return }
        Task { @MainActor in
            guard let reply = try? receiveWorkout(data), let session = self.session,
                  session.activationState == .activated else { return }
            session.transferUserInfo([WorkoutTransfer.receiptKey: reply])
        }
        #endif
    }

    #if targetEnvironment(simulator)
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                             replyHandler: @escaping @Sendable (Data) -> Void) {
        Task { @MainActor in
            let receipt = try? receiveWorkout(WorkoutTransfer.interactiveContents(messageData))
            replyHandler(receipt ?? Data())
        }
    }
    #endif
}
