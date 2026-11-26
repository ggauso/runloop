import CoreLocation
import Foundation
import RunloopCore
import Supabase

struct RoutingService {
    let client: SupabaseClient

    func manual(waypoints: [RouteCoordinate]) async throws -> RoutePreview {
        let session = try await client.auth.session
        let response: Response = try await request(ManualRequest(waypoints: waypoints), accessToken: session.accessToken)
        guard let preview = response.preview else { throw RoutingError.invalidResponse }
        return preview
    }

    func loopAlternatives(start: RouteCoordinate, waypoints: [RouteCoordinate]?, targetDistanceMeters: Int,
                          seeds: [Int]) async throws -> [RoutePreview] {
        let session = try await client.auth.session
        let batch: AlternativesResponse
        if let waypoints {
            batch = try await request(WaypointLoopRequest(waypoints: waypoints, seeds: seeds), accessToken: session.accessToken)
        } else {
            let offset = Int.random(in: 0..<360)
            let headings = seeds.indices.map { (offset + 360 * $0 / seeds.count) % 360 }
            batch = try await request(RoundTripRequest(start: start, targetDistanceMeters: targetDistanceMeters,
                                                       seeds: seeds, headings: headings),
                                      accessToken: session.accessToken)
        }
        try Task.checkCancellation()
        var geometries = Set<Int>()
        let alternatives = batch.alternatives.compactMap(\.preview).filter { geometries.insert($0.directionIndependentHash).inserted }
        guard !alternatives.isEmpty else { throw RoutingError.invalidResponse }
        return alternatives
    }

    private func request<Body: Encodable & Sendable, Output: Decodable>(_ body: Body, accessToken: String) async throws -> Output {
        try await client.functions.invoke(
            "routing",
            options: .init(headers: ["Authorization": "Bearer \(accessToken)"], body: body)
        )
    }

    static func message(for error: any Error) -> String {
        if let functionError = error as? FunctionsError, case .httpError(let status, let payload) = functionError {
            switch status {
            case 401, 403: return "Accedi di nuovo per calcolare il percorso."
            case 422:
                switch (try? JSONDecoder().decode(ProviderError.self, from: payload))?.code {
                case "outside_routing_coverage":
                    return "Un punto è fuori dalla zona coperta dal servizio. Scegli una partenza e tappe nella zona coperta."
                case "loop_unavailable":
                    return "Non trovo un ritorno diverso dall’andata. Riprova o sposta una tappa."
                default:
                    return "Non trovo un percorso pedonale tra questi punti. Sposta le tappe o scegli un’altra zona."
                }
            case 429: return "Hai raggiunto il limite di ricerche. Riprova tra un minuto."
            case 504: return "Il calcolo ha impiegato troppo tempo. Riprova."
            default: break
            }
        }
        if error is AuthError { return "Accedi di nuovo per calcolare il percorso." }
        if (error as NSError).domain == NSURLErrorDomain {
            return "Controlla la connessione e riprova a calcolare il percorso."
        }
        return "Non è stato possibile calcolare il percorso. Riprova tra poco."
    }

    private struct ManualRequest: Encodable, Sendable {
        let mode = RouteMode.manual
        let waypoints: [RouteCoordinate]
    }

    private struct RoundTripRequest: Encodable, Sendable {
        let mode = RouteMode.roundTrip
        let start: RouteCoordinate
        let targetDistanceMeters: Int
        let seeds: [Int]
        let headings: [Int]
    }

    private struct WaypointLoopRequest: Encodable, Sendable {
        let mode = RouteMode.waypointLoop
        let waypoints: [RouteCoordinate]
        let seeds: [Int]
    }

    private struct ProviderError: Decodable { let code: String }

    private struct Response: Decodable {
        let provider: String
        let distanceMeters: Double
        let geometry: RouteGeometry

        var preview: RoutePreview? {
            guard distanceMeters.isFinite, distanceMeters > 0, provider == "graphhopper" else { return nil }
            return RoutePreview(coordinates: geometry.coordinates, distanceMeters: distanceMeters, provider: provider)
        }
    }

    private struct AlternativesResponse: Decodable {
        let alternatives: [Response]
    }

    private enum RoutingError: Error { case invalidResponse }
}
