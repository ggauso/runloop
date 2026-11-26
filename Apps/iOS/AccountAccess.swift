import Foundation
import MapKit
import RunloopCore
import Supabase
import SwiftUI

@MainActor
@Observable
final class AccountAccess {
    let client: SupabaseClient?
    private(set) var session: Session?
    private(set) var isRestoring: Bool
    private(set) var isWorking = false
    private(set) var message: String?
    private var isSigningOut = false

    init() {
        if let configuration = BackendConfiguration() {
            client = SupabaseClient(
                supabaseURL: configuration.url,
                supabaseKey: configuration.key,
                options: SupabaseClientOptions(auth: .init(emitLocalSessionAsInitialSession: true))
            )
        } else {
            client = nil
        }
        isRestoring = client != nil
    }

    func observeSession() async {
        guard let client else { return }
        for await (event, updatedSession) in client.auth.authStateChanges {
            let wasSignedIn = session != nil
            session = updatedSession
            isRestoring = false
            if event == .signedOut, wasSignedIn, !isSigningOut {
                message = "La sessione è scaduta. Accedi di nuovo."
            } else if event == .tokenRefreshed {
                message = nil
            }
        }
    }

    func authenticate(email: String, password: String, creatingAccount: Bool) async -> Bool {
        guard let client, !isWorking else { return false }
        isWorking = true
        message = nil
        defer { isWorking = false }

        do {
            if creatingAccount {
                let result = try await client.auth.signUp(email: email, password: password)
                session = result.session
                if result.session == nil {
                    message = "Controlla la posta per confermare l’indirizzo, poi accedi."
                }
            } else {
                session = try await client.auth.signIn(email: email, password: password)
            }
            return true
        } catch {
            message = Self.message(for: error)
            return false
        }
    }

    func refreshSession() async {
        guard let client, !isWorking else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }

        do {
            session = try await client.auth.session
        } catch {
            message = Self.message(for: error)
            if let code = (error as? AuthError)?.errorCode,
               [.sessionNotFound, .sessionExpired, .refreshTokenNotFound, .refreshTokenAlreadyUsed, .invalidJWT].contains(code) {
                isSigningOut = true
                try? await client.auth.signOut(scope: .local)
                session = nil
                isSigningOut = false
            }
        }
    }

    func signOut() async {
        guard let client, !isWorking else { return }
        isWorking = true
        isSigningOut = true
        message = nil
        defer {
            isWorking = false
            isSigningOut = false
        }

        do {
            try await client.auth.signOut(scope: .local)
        } catch {
            message = "Sei uscito su questo iPhone. La connessione al server non è riuscita."
        }
        session = nil
    }

    private static func message(for error: any Error) -> String {
        if (error as NSError).domain == NSURLErrorDomain {
            return "Connessione non disponibile. Riprova quando torni online."
        }
        switch (error as? AuthError)?.errorCode {
        case .invalidCredentials: return "Email o password non corrette."
        case .emailNotConfirmed: return "Conferma l’indirizzo email prima di accedere."
        case .weakPassword: return "La password non soddisfa i requisiti. Scegline una più sicura."
        case .emailExists, .userAlreadyExists: return "Questo indirizzo è già registrato. Prova ad accedere."
        case .overEmailSendRateLimit, .overRequestRateLimit: return "Troppe richieste. Attendi un momento e riprova."
        case .sessionNotFound, .sessionExpired, .refreshTokenNotFound, .refreshTokenAlreadyUsed, .invalidJWT:
            return "La sessione è scaduta. Accedi di nuovo."
        default: return "Il servizio di accesso non è disponibile. Riprova tra poco."
        }
    }
}

private struct BackendConfiguration {
    let url: URL
    let key: String

    init?(bundle: Bundle = .main) {
        guard let scheme = bundle.object(forInfoDictionaryKey: "RunloopSupabaseScheme") as? String,
              let authority = bundle.object(forInfoDictionaryKey: "RunloopSupabaseAuthority") as? String,
              let key = bundle.object(forInfoDictionaryKey: "RunloopSupabasePublishableKey") as? String,
              Self.isPublicKey(key),
              let url = URL(string: "\(scheme)://\(authority)"), let host = url.host,
              url.user == nil, url.password == nil, url.path.isEmpty, url.query == nil, url.fragment == nil
        else { return nil }

        #if DEBUG && targetEnvironment(simulator)
        guard url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost"].contains(host)) else { return nil }
        #else
        guard url.scheme == "https" else { return nil }
        #endif

        self.url = url
        self.key = key
    }

    private static func isPublicKey(_ key: String) -> Bool {
        if key.hasPrefix("sb_publishable_") { return key.count > "sb_publishable_".count }
        let segments = key.split(separator: ".")
        guard segments.count == 3 else { return false }
        var payload = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return claims["role"] as? String == "anon"
    }
}

struct AccountView: View {
    var openRoutes: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PhoneWatchTransfer.self) private var watch
    @Environment(AccountAccess.self) private var access
    @Environment(WorkoutCloudSync.self) private var workoutCloud
    @Environment(\.runloopAccent) private var accent
    @AppStorage(RunloopAccent.storageKey) private var accentChoice = RunloopAccent.defaultChoice
    @State private var email = ""
    @State private var password = ""
    @State private var creatingAccount = false

    private var normalizedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                RunloopHeading(context: "Runloop  /  Preferenze", title: creatingAccount ? "Registrazione" : "Account")
            }.listRowBackground(Color.clear)
            Section {
                Text("Scegli l’accento di iPhone e Watch.").font(.subheadline).foregroundStyle(RunloopStyle.muted)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 6) {
                    ForEach(RunloopAccent.allCases, id: \.self) { choice in
                        Button {
                            withAnimation(reduceMotion ? nil : RunloopMotion.status) { accentChoice = choice }
                        } label: {
                            VStack(spacing: 8) {
                                Circle().fill(choice.color).frame(width: 30, height: 30)
                                    .overlay { if accentChoice == choice { Image(systemName: "checkmark").font(.footnote.bold()).foregroundStyle(RunloopStyle.canvas) } }
                                Text(choice.title).font(.caption)
                            }
                            .padding(.vertical, 9).frame(maxWidth: .infinity)
                            .background(RunloopStyle.panel, in: .rect(cornerRadius: RunloopStyle.radius))
                        }
                        .buttonStyle(RunloopPressStyle())
                        .accessibilityAddTraits(accentChoice == choice ? .isSelected : [])
                        .accessibilityIdentifier("account.accent.\(choice.rawValue)")
                    }
                }
                .sensoryFeedback(.selection, trigger: accentChoice)
            } header: { Text("Colore del percorso") }
            .listRowBackground(Color.clear)
            Section {
                colorPreview
                Button(openRoutes == nil ? "Torna indietro" : "Vai ai percorsi", systemImage: openRoutes == nil ? "chevron.backward" : "map") {
                    if let openRoutes { openRoutes() } else { dismiss() }
                }.buttonStyle(RunloopButtonStyle())
            } header: { Text("Anteprima") }
            .listRowBackground(Color.clear)
            if access.isRestoring {
                ProgressView("Ripristino dell’accesso…")
            } else if let session = access.session {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.largeTitle).foregroundStyle(accent)
                            .accessibilityHidden(true)
                        Text(session.user.email ?? "Account Runloop")
                            .font(RunloopType.sectionTitle)
                            .textSelection(.enabled)
                    }
                        .padding(.vertical, 10)
                        .accessibilityIdentifier("account.identity")
                    if session.isExpired {
                        Text("Il cloud è in pausa finché la sessione non si riconnette.")
                        Button("Riconnetti") { Task { await access.refreshSession() } }
                    }
                    Button("Esci", role: .destructive) { Task { await access.signOut() } }
                        .accessibilityIdentifier("account.signOut")
                }
                .listRowBackground(RunloopStyle.panel)
            } else if access.client != nil {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("account.email")
                    SecureField("Password", text: $password)
                        .textContentType(creatingAccount ? .newPassword : .password)
                        .accessibilityIdentifier("account.password")
                    Button(creatingAccount ? "Crea account" : "Accedi") { submit() }
                        .buttonStyle(RunloopButtonStyle())
                        .disabled(!normalizedEmail.contains("@") || password.count < (creatingAccount ? 6 : 1))
                        .accessibilityIdentifier("account.submit")
                } footer: {
                    Text("L’account serve per il routing online e la sincronizzazione. Gli allenamenti locali restano accessibili.")
                }
                .listRowBackground(RunloopStyle.panel)

                Button(creatingAccount ? "Ho già un account" : "Crea un account") {
                    creatingAccount.toggle()
                    password = ""
                }
                .listRowBackground(Color.clear)
            } else {
                ContentUnavailableView("Servizio non configurato", systemImage: "person.crop.circle.badge.exclamationmark",
                                       description: Text("Puoi comunque consultare i tuoi allenamenti locali."))
            }

            Section("Preferenze") {
                NavigationLink("Zone cardiache") { RunZoneEditor(runs: watch.runs) }
            }
            .listRowBackground(RunloopStyle.panel)

            if !access.isRestoring, access.session != nil {
                Section {
                    Toggle("Sincronizza frequenza cardiaca media", isOn: Binding(
                        get: { workoutCloud.sharesHeartRate },
                        set: { workoutCloud.setSharesHeartRate($0) }
                    ))
                } footer: {
                    Text("Se attivo, Runloop include la frequenza cardiaca media nelle prossime corse sincronizzate. I singoli campioni restano in Salute.")
                }
                .listRowBackground(RunloopStyle.panel)
            }

            if access.isWorking {
                ProgressView("Operazione in corso…")
            } else if let message = access.message {
                Text(message)
                    .foregroundStyle(RunloopStyle.muted)
                    .accessibilityIdentifier("account.status")
            }
        }
        .scrollContentBackground(.hidden)
        .runloopCanvas()
        .disabled(access.isWorking)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("")
        .toolbar(openRoutes == nil ? .visible : .hidden, for: .navigationBar)
    }

    private var colorPreview: some View {
        // The color sample follows the Crocetta loop used by the design prototype.
        let points = Self.sampleLoop
        return Map(initialPosition: .rect(routeMapRect(points)), interactionModes: []) {
            MapPolyline(coordinates: points.map(\.location)).stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .frame(height: 175).clipShape(.rect(cornerRadius: RunloopStyle.radius))
        .accessibilityLabel("Anteprima del colore sul percorso di esempio")
    }

    private static let sampleLoop: [RouteCoordinate] = [
        .init(latitude: 45.06099, longitude: 7.65860),
        .init(latitude: 45.06023, longitude: 7.66060),
        .init(latitude: 45.06058, longitude: 7.66107),
        .init(latitude: 45.06038, longitude: 7.66159),
        .init(latitude: 45.06229, longitude: 7.66295),
        .init(latitude: 45.06241, longitude: 7.66668),
        .init(latitude: 45.06605, longitude: 7.66935),
        .init(latitude: 45.06580, longitude: 7.67003),
        .init(latitude: 45.06603, longitude: 7.67019),
        .init(latitude: 45.06602, longitude: 7.67152),
        .init(latitude: 45.06726, longitude: 7.67237),
        .init(latitude: 45.06661, longitude: 7.67422),
        .init(latitude: 45.06807, longitude: 7.67525),
        .init(latitude: 45.06778, longitude: 7.67604),
        .init(latitude: 45.06321, longitude: 7.67279),
        .init(latitude: 45.06338, longitude: 7.67213),
        .init(latitude: 45.06308, longitude: 7.67086),
        .init(latitude: 45.06346, longitude: 7.66977),
        .init(latitude: 45.06228, longitude: 7.66889),
        .init(latitude: 45.06242, longitude: 7.66390),
        .init(latitude: 45.06275, longitude: 7.66338),
        .init(latitude: 45.06243, longitude: 7.66313),
        .init(latitude: 45.06244, longitude: 7.66240),
        .init(latitude: 45.06167, longitude: 7.66184),
        .init(latitude: 45.06197, longitude: 7.66099),
        .init(latitude: 45.06078, longitude: 7.66013),
        .init(latitude: 45.06140, longitude: 7.65839),
        .init(latitude: 45.06114, longitude: 7.65821),
        .init(latitude: 45.06099, longitude: 7.65860),
    ]

    private func submit() {
        let submittedPassword = password
        Task {
            let accepted = await access.authenticate(email: normalizedEmail, password: submittedPassword, creatingAccount: creatingAccount)
            password = ""
            if accepted { creatingAccount = false }
        }
    }
}
