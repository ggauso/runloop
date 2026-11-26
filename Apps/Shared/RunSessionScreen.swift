import RunloopCore
import SwiftUI

struct RunSessionScreen: View {
    let runs: RunCompanion
    @State private var editingZones = false
    @State private var choosingEnd = false
    @Environment(\.runloopAccent) private var accent

    private var isLocal: Bool { runs.local.isPresented }
    private var phase: RunWorkout.Phase { isLocal ? runs.local.phase : (runs.remote?.phase ?? .idle) }
    private var active: Bool { phase == .running || phase == .paused }
    private var needsLocationChoice: Bool { isLocal ? runs.local.needsLocationChoice : runs.remote?.needsLocationChoice == true }
    private var reachable: Bool { isLocal || runs.connected }
    private var title: String { isLocal ? runs.local.route?.payload.name ?? "Corsa libera" : runs.remote?.title ?? "Corsa libera" }

    var body: some View {
        Group {
            if let offer = runs.offer {
                VStack(alignment: .leading, spacing: 14) {
                    Text(offer.route?.payload.name ?? "Corsa libera").font(RunloopType.screenTitle)
                    Text("Dove vuoi registrare?").font(.headline)
                    Text(runs.notice ?? "Con Apple Watch vedi il battito al polso e su iPhone.").foregroundStyle(RunloopStyle.muted)
                    Button("Usa Apple Watch", systemImage: "applewatch") { runs.chooseRecorder(watch: true) }
                        .buttonStyle(RunloopButtonStyle())
                    Button("Usa iPhone", systemImage: "iphone") { runs.chooseRecorder(watch: false) }
                        .buttonStyle(RunloopButtonStyle(kind: .secondary))
                    Button("Annulla") { runs.cancelOffer() }.frame(maxWidth: .infinity, minHeight: 44)
                }.padding()
            } else if let notice = runs.notice, !isLocal, runs.remote == nil {
                VStack { Text(notice); Button("Chiudi") { runs.closeRemote() } }.padding()
            } else if isLocal || runs.remote != nil {
                dashboard
            } else { ProgressView("Avvio corsa…") }
        }
        .runloopCanvas()
        .sheet(isPresented: $editingZones) {
            NavigationStack { RunZoneEditor(runs: runs) }
                .preferredColorScheme(.dark).tint(accent)
        }
        .sheet(isPresented: $choosingEnd) {
            RunEndChoices(canDiscard: isLocal || runs.remote?.canDiscard == true, enabled: active && reachable) { decision in
                choosingEnd = false
                if let decision { perform(decision) }
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #endif
            .preferredColorScheme(.dark)
        }
        .onChange(of: active) { _, active in
            if !active { choosingEnd = false; editingZones = false }
        }
        .sensoryFeedback(trigger: phase) { previous, current in
            if current == .saved { return .success }
            if [.startFailed, .saveFailed, .discardFailed].contains(current) { return .error }
            if current == .paused || (previous == .paused && current == .running) { return .selection }
            return nil
        }
    }

    private var dashboardSpacing: CGFloat {
        #if os(watchOS)
        5
        #else
        12
        #endif
    }

    private var dashboard: some View {
        #if os(watchOS)
        // watchOS lets scrolling content extend under the time. Clip the viewport to the safe area.
        GeometryReader { viewport in
            dashboardScroll
                .frame(width: viewport.size.width, height: viewport.size.height)
                .clipped()
        }
        #else
        dashboardScroll
        #endif
    }

    private var dashboardScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: dashboardSpacing) {
                if !needsLocationChoice {
                    Text(title)
                        #if os(iOS)
                        .font(RunloopType.sectionTitle)
                        #else
                        .font(.footnote.weight(.semibold))
                        #endif
                        .accessibilityAddTraits(.isHeader)
                }
                if let run = runs.remote, !isLocal {
                    Label("Registrazione su " + run.source.displayName, systemImage: run.source == .watch ? "applewatch" : "iphone")
                        .font(.caption2).foregroundStyle(RunloopStyle.muted)
                }
                if !reachable {
                    Label("Collegamento interrotto", systemImage: "antenna.radiowaves.left.and.right.slash").font(.footnote)
                    Button("Chiudi") { runs.closeRemote() }
                }
                switch phase {
                case .running, .paused, .saved:
                    if phase == .saved {
                        Label(isLocal ? "Salvata in Salute" : "Corsa salvata", systemImage: "checkmark.circle.fill").foregroundStyle(accent)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { tick in
                        let remote = runs.remote
                        let elapsed = isLocal ? runs.local.elapsed(at: tick.date) :
                            (remote?.elapsed ?? 0) + (reachable && phase == .running ? max(0, tick.date.timeIntervalSince(remote?.date ?? tick.date)) : 0)
                        let distance = isLocal ? runs.local.distance : remote?.distance ?? 0
                        VStack(alignment: .leading, spacing: dashboardSpacing) {
                            RunClock(elapsed: elapsed, phase: phase)
                            #if os(iOS)
                            RunSplits(distance: distance, elapsed: elapsed)
                            #endif
                            if active {
                                RunIntensity(pulse: isLocal ? runs.local.pulse : remote?.pulse, date: tick.date, zones: runs.zones,
                                             connected: reachable, editing: { editingZones = true })
                            }
                            #if os(watchOS)
                            RunSplits(distance: distance, elapsed: elapsed)
                            #endif
                        }
                    }
                    #if os(watchOS)
                    if active && reachable { actions }
                    #endif
                    if phase == .saved { doneButton }
                    RunLiveMap(planned: isLocal ? runs.local.route?.payload.geometry.coordinates ?? [] : runs.remote?.planned ?? [],
                               trail: isLocal ? runs.local.recording.trail : runs.remote?.trail ?? [])
                    if isLocal, let warning = runs.local.message ?? runs.local.recording.warning {
                        Text(warning).font(.footnote).foregroundStyle(RunloopStyle.muted)
                    }
                case .starting where needsLocationChoice:
                    locationChoice
                case .discarded:
                    Label("Corsa scartata", systemImage: "trash").font(.headline)
                    doneButton
                case .startFailed, .saveFailed, .discardFailed:
                    Text(isLocal ? runs.local.message ?? "Operazione non riuscita." : "Controlla il dispositivo che registra.")
                    if isLocal && phase == .saveFailed {
                        Button("Riprova salvataggio") { runs.local.retrySave() }
                    } else if isLocal && phase == .discardFailed {
                        Button("Riprova scarto") { runs.local.discard() }
                    } else { doneButton }
                default:
                    ProgressView(phase == .saving ? "Salvataggio…" : "Avvio corsa…")
                }
            }
            .frame(maxWidth: 580, alignment: .leading)
            #if os(iOS)
            .padding(.horizontal, 22).padding(.vertical, 20)
            #else
            .padding(.horizontal, 8).padding(.bottom, 8)
            #endif
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
        .safeAreaInset(edge: .bottom) {
            if active && reachable {
                actions.padding(.horizontal, 20).padding(.vertical, 10)
                    .background(RunloopStyle.canvas).overlay(alignment: .top) { Divider() }
            }
        }
        #endif
    }

    private var locationChoice: some View {
        VStack(alignment: .leading, spacing: dashboardSpacing) {
            Text("GPS disattivato").font(.headline).accessibilityAddTraits(.isHeader)
            Text(isLocal ? "Attiva la posizione in Impostazioni." : "Attiva la posizione nelle Impostazioni del Watch.")
                .font(.footnote).foregroundStyle(RunloopStyle.muted)
            Button("Corri senza GPS") { resolveLocationChoice(recordWithoutGPS: true) }
                .buttonStyle(RunloopButtonStyle())
            Button("Annulla") { resolveLocationChoice(recordWithoutGPS: false) }
                .buttonStyle(RunloopButtonStyle(kind: .secondary))
        }
        .disabled(!reachable || (!isLocal && runs.sending))
    }

    private func resolveLocationChoice(recordWithoutGPS: Bool) {
        if isLocal { runs.local.resolveLocationChoice(recordWithoutGPS: recordWithoutGPS) }
        else { runs.command(recordWithoutGPS ? .continueWithoutGPS : .cancelStart) }
    }

    private var doneButton: some View {
        Button("Fine") {
            if isLocal { runs.local.close() } else { runs.closeRemote() }
        }.buttonStyle(RunloopButtonStyle())
    }

    private var actions: some View {
        Group {
            #if os(watchOS)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { actionButtons(compact: true) }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(spacing: 4) { actionButtons(compact: false) }
            }
            .frame(maxWidth: .infinity)
            #else
            HStack(spacing: 6) { actionButtons(compact: false) }
            #endif
        }
        .disabled(!isLocal && runs.sending)
    }

    @ViewBuilder private func actionButtons(compact: Bool) -> some View {
        Button(phase == .paused ? "Riprendi" : "Pausa") {
            perform(phase == .paused ? .resume : .pause)
        }
        .buttonStyle(RunloopButtonStyle(compact: compact))
        Button("Termina") { choosingEnd = true }
            .buttonStyle(RunloopButtonStyle(kind: .secondary, compact: compact))
    }

    private func perform(_ action: RunCompanion.Action) {
        guard active && reachable else { return }
        if !isLocal { runs.command(action); return }
        switch action {
        case .pause where phase == .running, .resume where phase == .paused: runs.local.togglePause()
        case .finish: runs.local.stop()
        case .discard: runs.local.discard()
        default: break
        }
    }
}

private struct RunEndChoices: View {
    let canDiscard: Bool
    let enabled: Bool
    let select: (RunCompanion.Action?) -> Void
    @State private var confirming = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(confirming ? "Scartare questa corsa?" : "Termina corsa")
                    .font(RunloopType.sectionTitle).accessibilityAddTraits(.isHeader)
                if confirming {
                    Text("Tempo, distanza e traccia di questa sessione andranno persi.")
                        .font(.footnote).foregroundStyle(RunloopStyle.muted)
                    Button("Scarta corsa", role: .destructive) { select(.discard) }
                        .buttonStyle(RunloopButtonStyle(kind: .destructive)).disabled(!enabled)
                } else {
                    Button("Salva corsa") { select(.finish) }.buttonStyle(RunloopButtonStyle()).disabled(!enabled)
                    if canDiscard {
                        Button("Scarta senza salvare") { confirming = true }
                            .buttonStyle(RunloopButtonStyle(kind: .destructive)).disabled(!enabled)
                    }
                }
                Button("Torna alla corsa") { select(nil) }.buttonStyle(RunloopButtonStyle(kind: .secondary))
            }
            .animation(reduceMotion ? nil : RunloopMotion.status, value: confirming)
            .padding()
        }.runloopCanvas()
    }
}

private struct RunClock: View {
    let elapsed: Double
    let phase: RunWorkout.Phase
    @Environment(\.runloopAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(phase == .paused ? "In pausa" : "Tempo attivo", systemImage: phase == .paused ? "pause.fill" : "timer")
                .font(.caption2.weight(.semibold)).foregroundStyle(phase == .paused ? RunloopStyle.paused : RunloopStyle.muted)
            Text(Duration.seconds(elapsed).formatted(.time(pattern: .hourMinuteSecond)))
                #if os(iOS)
                .font(RunloopType.display(size: 72, relativeTo: .largeTitle))
                #else
                .font(RunloopType.display(size: 42, relativeTo: .largeTitle))
                #endif
                .monospacedDigit().foregroundStyle(phase == .paused ? RunloopStyle.paused : accent)
                .lineLimit(1).minimumScaleFactor(0.65)
        }.accessibilityElement(children: .combine).accessibilityIdentifier("run.elapsed")
    }
}

private struct RunSplits: View {
    let distance: Double
    let elapsed: Double

    var body: some View {
        HStack(alignment: .top) {
            metric("Distanza", routeDistanceText(distance))
            metric("Passo medio", runPaceText(duration: elapsed, distance: distance))
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).foregroundStyle(RunloopStyle.muted).font(.caption2)
            Text(value).font(.headline.monospacedDigit()).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}

private struct RunIntensity: View {
    let pulse: PulseReading?
    let date: Date
    let zones: HeartZones
    let connected: Bool
    let editing: () -> Void
    @Environment(\.runloopAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var reading: Double? { connected && pulse?.isCurrent(at: date) == true ? pulse?.bpm : nil }
    private var zone: Int? { reading.flatMap(zones.zone(for:)) }
    private var status: String {
        guard let zone else {
            if !connected || (pulse != nil && reading == nil) { return "Segnale perso" }
            return reading == nil ? "In attesa del sensore" : "Imposta la FC massima"
        }
        guard let target = zones.target else { return "Zona " + String(zone) }
        return "Z" + String(zone) + " · " + (zone == target ? "In obiettivo" : zone < target ? "Sotto Z" + String(target) : "Sopra Z" + String(target))
    }

    var body: some View {
        Button(action: editing) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Battito", systemImage: "heart.fill").font(.caption.weight(.semibold))
                    Spacer()
                    Image(systemName: "slider.horizontal.3").foregroundStyle(RunloopStyle.muted)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(reading.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—")
                        #if os(iOS)
                        .font(RunloopType.metric)
                        #else
                        .font(RunloopType.compactMetric)
                        #endif
                    Text("bpm").font(.caption2)
                    Spacer()
                    Text(status).font(.caption2.weight(.semibold)).multilineTextAlignment(.trailing)
                }
                HStack(spacing: 3) {
                    ForEach(1...5, id: \.self) { number in
                        VStack(spacing: 4) {
                            #if os(iOS)
                            Text("Z\(number)").font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(zone == number ? accent : RunloopStyle.muted)
                            #endif
                            Capsule().fill(zone == number ? accent : RunloopStyle.raised)
                                .overlay { if zones.target == number { Capsule().strokeBorder(RunloopStyle.text, lineWidth: 1) } }
                                .frame(height: 5)
                        }.frame(maxWidth: .infinity)
                    }
                }.animation(reduceMotion ? nil : RunloopMotion.status, value: zone)
                #if os(iOS)
                if let target = zones.target {
                    Text("Obiettivo Z\(target) · " + zones.rangeText(target))
                        .font(.footnote).foregroundStyle(RunloopStyle.muted).padding(.top, 3)
                }
                #endif
            }
            #if os(iOS)
            .padding(16)
            #else
            .padding(8)
            #endif
            .background(RunloopStyle.panel, in: .rect(cornerRadius: RunloopStyle.radius))
        }
        .buttonStyle(RunloopPressStyle()).accessibilityIdentifier("run.intensity")
        .accessibilityLabel("Battito, " + (reading.map { $0.formatted(.number.precision(.fractionLength(0))) + " bpm, " } ?? "") + status)
        .accessibilityHint("Modifica FC massima e zona obiettivo")
    }
}

struct RunZoneEditor: View {
    let runs: RunCompanion
    @State private var maximum: Int
    @State private var target: Int
    @State private var input: String
    @Environment(\.dismiss) private var dismiss

    init(runs: RunCompanion) {
        self.runs = runs
        _maximum = State(initialValue: runs.zones.maximum ?? 0)
        _input = State(initialValue: runs.zones.maximum.map(String.init) ?? "")
        _target = State(initialValue: runs.zones.target ?? 0)
    }

    var body: some View {
        Form {
            Section("Frequenza cardiaca massima") {
                #if os(iOS)
                TextField("FC massima in bpm", text: $input)
                    .keyboardType(.numberPad).accessibilityIdentifier("zones.maximum")
                    .onChange(of: input) { _, value in maximum = Int(value) ?? 0 }
                if !input.isEmpty && !(60...250).contains(maximum) {
                    Text("Inserisci un valore tra 60 e 250 bpm.").font(.footnote)
                }
                #else
                if maximum == 0 {
                    Button("Imposta FC massima") { maximum = 180 }
                } else {
                    Picker("FC massima", selection: $maximum) {
                        ForEach(60...250, id: \.self) { Text("\($0) bpm").tag($0) }
                    }.pickerStyle(.wheel)
                    Button("Rimuovi FC massima") { maximum = 0 }
                }
                #endif
            }
            if (60...250).contains(maximum) {
                Section("Obiettivo durante la corsa") {
                    Picker("Zona obiettivo", selection: $target) {
                        Text("Libera").tag(0)
                        ForEach(1...5, id: \.self) { Text("Zona \($0)").tag($0) }
                    }
                    let profile = HeartZones(maximum: maximum)
                    ForEach(1...5, id: \.self) { z in
                        LabeledContent("Z\(z)", value: profile.rangeText(z))
                    }
                }
            }
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                #if os(watchOS)
                Button("Applica", systemImage: "checkmark", action: apply).labelStyle(.iconOnly)
                #else
                Button("Applica", action: apply)
                    .disabled(!input.isEmpty && !(60...250).contains(maximum))
                #endif
            }
        }
        .navigationTitle("Zone cardiache")
    }

    private func apply() {
        runs.setZones(maximum: maximum == 0 ? nil : maximum, target: maximum == 0 || target == 0 ? nil : target)
        dismiss()
    }

}

private extension HeartZones {
    func rangeText(_ zone: Int) -> String {
        guard let maximum else { return "—" }
        if let next = lowerLimit(for: zone + 1) {
            if let lower = lowerLimit(for: zone) { return "\(lower)–\(next - 1) bpm" }
            return "< \(next) bpm"
        }
        return "≥ \(lowerLimit(for: zone) ?? maximum) bpm"
    }
}
