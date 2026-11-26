import RunloopCore
import SwiftUI

struct RunSessionScreen: View {
    let runs: RunCompanion
    var onSavedClose: (() -> Void)? = nil
    @State private var editingZones = false
    @State private var choosingEnd = false
    @Environment(\.runloopAccent) private var accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isLocal: Bool { runs.local.isPresented }
    private var phase: RunWorkout.Phase { isLocal ? runs.local.phase : (runs.remote?.phase ?? .idle) }
    private var active: Bool { phase == .running || phase == .paused }
    private var needsLocationChoice: Bool { isLocal ? runs.local.needsLocationChoice : runs.remote?.needsLocationChoice == true }
    private var reachable: Bool { isLocal || runs.connected }
    private var title: String { isLocal ? runs.local.route?.payload.name ?? "Corsa libera" : runs.remote?.title ?? "Corsa libera" }

    private var distance: Double { isLocal ? runs.local.distance : runs.remote?.distance ?? 0 }
    private var followsRoute: Bool { isLocal ? runs.local.route != nil : runs.remote?.planned.isEmpty == false }

    private var recorder: String {
        if !isLocal, let source = runs.remote?.source { return source.displayName }
        #if os(watchOS)
        return "Apple Watch"
        #else
        return "iPhone"
        #endif
    }

    private func elapsed(at date: Date) -> TimeInterval {
        if isLocal { return runs.local.elapsed(at: date) }
        guard let remote = runs.remote else { return 0 }
        return remote.elapsed + (reachable && phase == .running ? max(0, date.timeIntervalSince(remote.date)) : 0)
    }

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
            RunEndChoices(distance: distance, elapsed: elapsed(at: .now), canDiscard: isLocal || runs.remote?.canDiscard == true, enabled: active && reachable) { decision in
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
        4
        #else
        18
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
                    #if os(iOS)
                    let context = phase == .saved ? "Allenamento" : followsRoute ? "Corsa su percorso" : "Corsa libera"
                    Text((context + "  /  " + recorder).uppercased())
                        .font(RunloopType.readout).foregroundStyle(RunloopStyle.muted)
                        .accessibilityAddTraits(.isHeader)
                    if active {
                        Text(followsRoute ? title : "Sessione libera").font(RunloopType.readout)
                            .textCase(.uppercase).foregroundStyle(RunloopStyle.muted)
                    }
                    #else
                    if !isLocal {
                        Text("Registrazione su " + recorder).font(.caption2).foregroundStyle(RunloopStyle.muted)
                    }
                    #endif
                }
                if !reachable {
                    Label("Collegamento interrotto", systemImage: "antenna.radiowaves.left.and.right.slash").font(.footnote)
                    Button("Chiudi") { runs.closeRemote() }
                }
                switch phase {
                case .running, .paused:
                    TimelineView(.periodic(from: .now, by: 1)) { tick in
                        VStack(alignment: .leading, spacing: dashboardSpacing) {
                            RunClock(elapsed: elapsed(at: tick.date), phase: phase)
                            #if os(iOS)
                            Divider()
                            #endif
                            RunSplits(distance: distance, elapsed: elapsed(at: tick.date))
                            #if os(watchOS)
                            let pulse = isLocal ? runs.local.pulse : runs.remote?.pulse
                            RunZoneStrip(zone: reachable && pulse?.isCurrent(at: tick.date) == true ? pulse.flatMap { runs.zones.zone(for: $0.bpm) } : nil,
                                         target: runs.zones.target, tint: phase == .paused ? RunloopStyle.paused : accent)
                            if reachable { actions }
                            #endif
                            RunIntensity(pulse: isLocal ? runs.local.pulse : runs.remote?.pulse, date: tick.date, zones: runs.zones,
                                         connected: reachable, editing: { editingZones = true })
                        }
                    }
                    liveMap
                    if isLocal, let warning = runs.local.message ?? runs.local.recording.warning {
                        Text(warning).font(.footnote).foregroundStyle(RunloopStyle.muted)
                    }
                case .saved:
                    Label("Registrazione salvata", systemImage: "checkmark.circle.fill")
                        .font(RunloopType.readout).foregroundStyle(accent)
                    Text(routeDistanceText(distance))
                        #if os(iOS)
                        .font(RunloopType.display(size: 84, relativeTo: .largeTitle))
                        #else
                        .font(RunloopType.display(size: 47, relativeTo: .title)).foregroundStyle(accent)
                        #endif
                        .lineLimit(1).minimumScaleFactor(0.6)
                    #if os(iOS)
                    Text(title).font(RunloopType.sectionTitle)
                    liveMap
                    #endif
                    let total = elapsed(at: .now)
                    Text(runClockText(total) + "   ·   " + runPaceText(duration: total, distance: distance))
                        .font(RunloopType.readout).foregroundStyle(RunloopStyle.muted)
                    doneButton
                    #if os(watchOS)
                    liveMap
                    #endif
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
        #if os(watchOS)
        .contentMargins(.vertical, 0, for: .scrollContent)
        #else
        .safeAreaInset(edge: .bottom) {
            if active && reachable {
                actions.padding(.horizontal, 20).padding(.vertical, 10)
                    .background(RunloopStyle.canvas).overlay(alignment: .top) { Divider() }
            }
        }
        #endif
    }

    private var liveMap: some View {
        RunLiveMap(planned: isLocal ? runs.local.route?.payload.geometry.coordinates ?? [] : runs.remote?.planned ?? [],
                   trail: isLocal ? runs.local.recording.trail : runs.remote?.trail ?? [])
    }

    private var locationChoice: some View {
        VStack(alignment: .leading, spacing: dashboardSpacing) {
            Text("GPS disattivato").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Per registrare la traccia, attiva la posizione nelle impostazioni di " + recorder + ".")
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
        Button(phase == .saved ? (onSavedClose == nil ? "Percorsi" : "Vedi allenamenti") : "Fine", systemImage: "arrow.right") {
            let saved = phase == .saved
            if isLocal { runs.local.close() } else { runs.closeRemote() }
            if saved { onSavedClose?() }
        }.buttonStyle(RunloopButtonStyle()).accessibilityIdentifier("run.done")
    }

    private var actions: some View {
        Group {
            #if os(watchOS)
            if typeSize >= .xxLarge {
                VStack(spacing: 4) { actionButtons(compact: false) }
            } else {
                HStack(spacing: 4) { actionButtons(compact: true) }
            }
            #else
            VStack(spacing: 8) { actionButtons(compact: false) }
            #endif
        }
        .contentTransition(reduceMotion ? .identity : .opacity)
        .animation(reduceMotion ? nil : RunloopMotion.status, value: phase == .paused)
        .disabled(!isLocal && runs.sending)
    }

    @ViewBuilder private func actionButtons(compact: Bool) -> some View {
        Button(phase == .paused ? "Riprendi" : "Pausa", systemImage: phase == .paused ? "play.fill" : "pause.fill") {
            perform(phase == .paused ? .resume : .pause)
        }
        .buttonStyle(RunloopButtonStyle(kind: phase == .paused ? .primary : .secondary, compact: compact, fillsAvailableWidth: compact))
        Button("Termina", systemImage: "stop.fill") { choosingEnd = true }
            .buttonStyle(RunloopButtonStyle(kind: .destructive, compact: compact, fillsAvailableWidth: compact))
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
    let distance: Double
    let elapsed: TimeInterval
    let canDiscard: Bool
    let enabled: Bool
    let select: (RunCompanion.Action?) -> Void
    @State private var confirming = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(confirming ? "CONFERMA SCARTO" : "FINE SESSIONE")
                    .font(RunloopType.readout).foregroundStyle(confirming ? RunloopStyle.danger : RunloopStyle.muted)
                #if os(iOS)
                Text(confirming ? "Scartare la corsa?" : "Terminare la corsa?")
                    .font(RunloopType.display(size: 39, relativeTo: .title)).accessibilityAddTraits(.isHeader)
                #else
                Text(confirming ? "Scartare?" : "Terminare?")
                    .font(RunloopType.sectionTitle).accessibilityAddTraits(.isHeader)
                #endif
                if confirming {
                    Text("La registrazione e la traccia GPS verranno eliminate.")
                        .font(.footnote).foregroundStyle(RunloopStyle.muted)
                    Button("Conserva la corsa", systemImage: "arrow.uturn.backward") { confirming = false }
                        .buttonStyle(RunloopButtonStyle())
                    Button("Scarta corsa", role: .destructive) { select(.discard) }
                        .buttonStyle(RunloopButtonStyle(kind: .destructive)).disabled(!enabled)
                } else {
                    #if os(iOS)
                    Text(runClockText(elapsed) + " di tempo attivo  ·  " + routeDistanceText(distance))
                        .font(.subheadline).foregroundStyle(RunloopStyle.muted).padding(.bottom, 6)
                    #endif
                    Button("Salva corsa", systemImage: "checkmark") { select(.finish) }
                        .buttonStyle(RunloopButtonStyle()).disabled(!enabled)
                    Button("Torna alla corsa", systemImage: "arrow.uturn.backward") { select(nil) }
                        .buttonStyle(RunloopButtonStyle(kind: .secondary))
                    if canDiscard {
                        Button("Scarta senza salvare") { confirming = true }
                            .buttonStyle(RunloopButtonStyle(kind: .destructive)).disabled(!enabled)
                    }
                }
            }
            .animation(reduceMotion ? nil : RunloopMotion.status, value: confirming)
            .padding()
        }.runloopCanvas()
    }
}

private func runClockText(_ seconds: TimeInterval) -> String {
    let duration = Duration.seconds(max(0, seconds.rounded(.down)))
    return seconds >= 3600 ? duration.formatted(.time(pattern: .hourMinuteSecond))
        : duration.formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
}

private struct RunClock: View {
    let elapsed: Double
    let phase: RunWorkout.Phase
    @ScaledMetric(relativeTo: .caption2) private var watchStatusSize: CGFloat = 10
    @Environment(\.runloopAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let paused = phase == .paused
        VStack(alignment: .leading, spacing: 0) {
            #if os(watchOS)
            Text(paused ? "IN PAUSA" : "IN CORSA")
                .font(.system(size: watchStatusSize, weight: .medium, design: .monospaced)).foregroundStyle(paused ? RunloopStyle.paused : RunloopStyle.muted)
            #else
            Label(paused ? "In pausa" : "In registrazione", systemImage: paused ? "pause.fill" : "figure.run")
                .contentTransition(reduceMotion ? .identity : .opacity)
                .font(.caption.weight(.semibold)).foregroundStyle(paused ? RunloopStyle.paused : accent)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RunloopStyle.raised, in: Capsule())
                .padding(.bottom, 23)
            Text("TEMPO ATTIVO").font(RunloopType.readout).foregroundStyle(RunloopStyle.muted)
            #endif
            Text(runClockText(elapsed))
                #if os(iOS)
                .font(RunloopType.display(size: 118, relativeTo: .largeTitle))
                #else
                .font(RunloopType.display(size: 57, relativeTo: .largeTitle))
                .padding(.vertical, -2)
                #endif
                .monospacedDigit().foregroundStyle(paused ? RunloopStyle.paused : RunloopStyle.text)
                .lineLimit(1).minimumScaleFactor(0.48)
        }
        .animation(reduceMotion ? nil : RunloopMotion.status, value: paused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((paused ? "In pausa" : "In corsa") + ", tempo attivo " + runClockText(elapsed))
        .accessibilityIdentifier("run.elapsed")
    }
}

private struct RunSplits: View {
    let distance: Double
    let elapsed: Double

    @ScaledMetric(relativeTo: .caption) private var watchSize: CGFloat = 12

    var body: some View {
        #if os(watchOS)
        let pace = runPaceText(duration: elapsed, distance: distance)
        Text(routeDistanceText(distance) + "    ·    " + pace)
            .font(.system(size: watchSize, weight: .medium, design: .monospaced))
            .accessibilityLabel("Distanza " + routeDistanceText(distance) + ", passo medio " + (pace == "—" ? "non disponibile" : pace))
        #else
        HStack(alignment: .top) {
            metric("Distanza", routeDistanceText(distance))
            metric("Passo medio", runPaceText(duration: elapsed, distance: distance))
        }
        #endif
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).foregroundStyle(RunloopStyle.muted).font(.caption2.monospaced())
            Text(value).font(RunloopType.display(size: 34, relativeTo: .title).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}

private struct RunZoneStrip: View {
    let zone: Int?
    let target: Int?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { number in
                Capsule().fill(zone == number ? tint : RunloopStyle.border)
                    .overlay { if target == number { Capsule().strokeBorder(RunloopStyle.text, lineWidth: 1) } }
                    .frame(height: zone == number ? 6 : 3)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 8)
        .animation(reduceMotion ? nil : RunloopMotion.status, value: zone)
        .accessibilityHidden(true)
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
                    Label {
                        Text("BATTITO").font(RunloopType.readout).foregroundStyle(RunloopStyle.muted)
                    } icon: {
                        Image(systemName: "heart.fill").foregroundStyle(accent)
                    }
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
                #if os(iOS)
                RunZoneStrip(zone: zone, target: zones.target, tint: accent)
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
