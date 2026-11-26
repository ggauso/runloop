import Foundation
import Observation
import RunloopCore
@preconcurrency import WatchConnectivity

@MainActor
@Observable
final class WatchRouteInbox: NSObject, WCSessionDelegate {
    private static let ownerKey = "runloop.watchOwner"
    private let archive = WatchRouteArchive(
        directory: URL.applicationSupportDirectory.appending(path: "Runloop/Routes", directoryHint: .isDirectory)
    )
    private var ownerID: UUID?
    var currentOwner: UUID? { ownerID }
    private var session: WCSession?
    let runs = RunCompanion()
    private(set) var recent: [RunBrief] = []
    let workouts = WatchWorkoutOutbox()
    private(set) var routes: [SyncEnvelope<RouteTransfer>] = []
    private(set) var readFailed = false

    override init() {
        super.init()
        ownerID = UserDefaults.standard.string(forKey: Self.ownerKey).flatMap(UUID.init(uuidString:))
        runs.setOwner(ownerID)
        if let data = UserDefaults.standard.data(forKey: RunBrief.contextKey),
           let cached = try? JSONDecoder().decode([RunBrief].self, from: data) { recent = cached }
        refresh()
        workouts.refresh()
        guard WCSession.isSupported() else { return }
        session = WCSession.default
        session?.delegate = self
        session?.activate()
    }

    private func refresh() {
        routes = []
        readFailed = false
        guard let ownerID else { return }
        do { routes = try archive.routes(for: ownerID) }
        catch { readFailed = true }
    }

    private func applyOwner(_ value: String) {
        ownerID = UUID(uuidString: value)
        runs.setOwner(ownerID)
        recent = []
        UserDefaults.standard.removeObject(forKey: RunBrief.contextKey)
        UserDefaults.standard.set(ownerID?.uuidString, forKey: Self.ownerKey)
        refresh()
    }

    private func applyPreferences(owner: String?, accent: String?, history: Data?) {
        if let owner, UUID(uuidString: owner) != ownerID { applyOwner(owner) }
        if let owner, UUID(uuidString: owner) == ownerID, let history,
           let list = try? JSONDecoder().decode([RunBrief].self, from: history) {
            recent = list
            UserDefaults.standard.set(history, forKey: RunBrief.contextKey)
        }
        if let accent, RunloopAccent(rawValue: accent) != nil {
            UserDefaults.standard.set(accent, forKey: RunloopAccent.storageKey)
        }
    }

    private func receive(_ data: Data) throws -> Data {
        let receipt = try archive.receive(data)
        if ownerID == receipt.ownerID { refresh() }
        return try JSONEncoder().encode(receipt)
    }

    func planRoute(_ draft: RouteDraft, action: WatchRouteRequest.Action) async throws -> WatchRouteReply {
        guard let ownerID else { throw WatchRouteError("Accedi a Runloop su iPhone per creare percorsi.") }
        guard let session, session.activationState == .activated, session.isReachable else {
            throw WatchRouteError("Avvicina l’iPhone e apri Runloop per riprovare.", disconnected: true)
        }
        let request = WatchRouteRequest(ownerID: ownerID, draft: draft, action: action)
        let selectedData = try WatchRouteMessage.encode(request)
        do {
            try await runs.checkPhoneConnection(using: session)
        } catch {
            try Task.checkCancellation()
            throw WatchRouteError("Collegamento con iPhone interrotto. Avvicina l’iPhone e riprova.", disconnected: true)
        }
        try Task.checkCancellation()
        guard self.ownerID == ownerID else { throw WatchRouteError("L’account è cambiato. Riapri il percorso.") }
        let data: Data?
        do {
            // Allow time for authentication and the routing provider once the phone has answered.
            data = try await session.runloopReply(to: selectedData, key: WatchRouteMessage.requestKey,
                                                  replyKey: WatchRouteMessage.replyKey, timeout: .seconds(40))
        } catch let error as URLError where error.code == .timedOut {
            throw WatchRouteError("L’iPhone non ha risposto in tempo. Riprova.")
        } catch {
            try Task.checkCancellation()
            throw WatchRouteError("Collegamento con iPhone interrotto. Riprova.", disconnected: true)
        }
        guard let data, let reply = try? WatchRouteMessage.decode(WatchRouteReply.self, from: data) else {
            throw WatchRouteError("Risposta dell’iPhone non disponibile. Riprova.")
        }
        guard self.ownerID == ownerID else { throw WatchRouteError("L’account è cambiato. Riapri il percorso.") }
        if case .failure(let message) = reply { throw WatchRouteError(message) }
        if case .saved(let route) = reply {
            guard route.payload.ownerID == ownerID else { throw WatchRouteError("Percorso non disponibile.") }
            _ = try receive(JSONEncoder().encode(route))
        }
        return reply
    }

    func syncWorkouts() {
        if let session { workouts.flush(using: session) }
        else { workouts.refresh() }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {
        guard activationState == .activated else { return }
        let context = session.receivedApplicationContext
        let owner = context[RouteTransferKeys.owner] as? String
        let accent = context[RunloopAccent.contextKey] as? String
        let history = context[RunBrief.contextKey] as? Data
        Task { @MainActor in
            applyPreferences(owner: owner, accent: accent, history: history)
            syncWorkouts()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let owner = applicationContext[RouteTransferKeys.owner] as? String
        let accent = applicationContext[RunloopAccent.contextKey] as? String
        let history = applicationContext[RunBrief.contextKey] as? Data
        Task { @MainActor in applyPreferences(owner: owner, accent: accent, history: history) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable { Task { @MainActor in syncWorkouts() } }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        guard error != nil, let identifier = fileTransfer.file.metadata?[WorkoutTransfer.metadataKey] as? String,
              let id = UUID(uuidString: identifier) else { return }
        Task { @MainActor in workouts.noteFailedDelivery(for: id) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let data = userInfo[WorkoutTransfer.deletionKey] as? Data,
           let receipt = try? JSONDecoder().decode(WorkoutReceipt.self, from: data) {
            Task { @MainActor in
                do {
                    try workouts.delete(receipt, currentOwner: ownerID)
                    if let session = self.session, session.activationState == .activated {
                        session.transferUserInfo([WorkoutTransfer.deletionReceiptKey: data])
                    }
                } catch {}
            }
            return
        }
        guard let data = userInfo[WorkoutTransfer.receiptKey] as? Data,
              let receipt = try? JSONDecoder().decode(WorkoutReceipt.self, from: data) else { return }
        Task { @MainActor in workouts.confirm(receipt) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        #if !targetEnvironment(simulator)
        guard let values = try? file.fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= RouteTransferKeys.byteLimit,
              let data = try? Data(contentsOf: file.fileURL) else { return }
        Task { @MainActor in
            guard let reply = try? receive(data), let session = self.session,
                  session.activationState == .activated else { return }
            session.transferUserInfo([RouteTransferKeys.receipt: reply])
        }
        #endif
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping @Sendable ([String: Any]) -> Void) {
        if let data = message[RunCompanion.key] as? Data {
            Task { @MainActor in replyHandler([RunCompanion.key: await runs.respond(data)]) }
            return
        }
        guard let data = message[WorkoutTransfer.deletionKey] as? Data,
              let receipt = try? JSONDecoder().decode(WorkoutReceipt.self, from: data) else {
            replyHandler([:])
            return
        }
        Task { @MainActor in
            do {
                try workouts.delete(receipt, currentOwner: ownerID)
                replyHandler([WorkoutTransfer.deletionReceiptKey: true])
            } catch {
                replyHandler([WorkoutTransfer.deletionReceiptKey: false])
            }
        }
    }

    #if targetEnvironment(simulator)
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                             replyHandler: @escaping @Sendable (Data) -> Void) {
        Task { @MainActor in replyHandler((try? receive(messageData)) ?? Data()) }
    }
    #endif
}

struct WatchRouteError: LocalizedError {
    let errorDescription: String?

    let disconnected: Bool

    init(_ message: String, disconnected: Bool = false) {
        errorDescription = message
        self.disconnected = disconnected
    }
}
