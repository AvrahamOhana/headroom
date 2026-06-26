//
//  ContentView.swift
//  NamRig — modeler UI: preset brain, chain strip, per-block editor.
//  Tuner + metrics live in pop-up sheets to keep the main screen clean.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum ChainBlock: String, CaseIterable, Identifiable {
    case gate, comp, boost, drive, pedal, amp, eq, chorus, flanger, tremolo, delay, reverb
    var id: String { rawValue }

    var kind: BlockKind {
        switch self {
        case .gate: return .gate; case .comp: return .comp; case .boost: return .boost; case .drive: return .drive
        case .pedal: return .pedal; case .amp: return .amp; case .eq: return .eq
        case .chorus: return .chorus; case .flanger: return .flanger; case .tremolo: return .tremolo
        case .delay: return .delay; case .reverb: return .reverb
        }
    }
    init?(_ k: BlockKind) {
        switch k {
        case .gate: self = .gate; case .comp: self = .comp; case .boost: self = .boost; case .drive: self = .drive
        case .pedal: self = .pedal; case .amp: self = .amp; case .eq: self = .eq
        case .chorus: self = .chorus; case .flanger: self = .flanger; case .tremolo: self = .tremolo
        case .delay: self = .delay; case .reverb: self = .reverb
        }
    }

    var short: String {
        switch self {
        case .gate: return "GATE"; case .comp: return "COMP"; case .boost: return "BST"; case .drive: return "DRV"
        case .pedal: return "PED"; case .amp: return "AMP"; case .eq: return "EQ"; case .chorus: return "CHO"; case .flanger: return "FLG"
        case .tremolo: return "TRM"; case .delay: return "DLY"; case .reverb: return "RVB"
        }
    }
    var full: String {
        switch self {
        case .gate: return "Noise Gate"; case .comp: return "Compressor"; case .boost: return "Clean Boost"; case .drive: return "Drive"
        case .pedal: return "Pedal"; case .amp: return "Amp"; case .eq: return "EQ"; case .chorus: return "Chorus"; case .flanger: return "Flanger"
        case .tremolo: return "Tremolo"; case .delay: return "Delay"; case .reverb: return "Reverb"
        }
    }
    var icon: String {
        switch self {
        case .gate: return "waveform.path.ecg"; case .comp: return "dial.medium"; case .boost: return "bolt.fill"; case .drive: return "flame.fill"
        case .pedal: return "dial.low.fill"; case .amp: return "amplifier"; case .eq: return "slider.vertical.3"; case .chorus: return "water.waves"; case .flanger: return "wind"
        case .tremolo: return "metronome"; case .delay: return "timer"; case .reverb: return "drop.fill"
        }
    }
    var color: Color {
        switch self {
        case .gate: return .teal; case .comp: return .blue; case .boost: return .yellow; case .drive: return .orange
        case .pedal: return .brown; case .amp: return .red; case .eq: return .green; case .chorus: return .mint; case .flanger: return .indigo
        case .tremolo: return .pink; case .delay: return .purple; case .reverb: return .cyan
        }
    }
}

struct ContentView: View {
    @State private var audio = AudioEngine()
    @State private var selected: ChainBlock = .amp
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSave = false
    @State private var newName = ""
    @State private var showTuner = false
    @State private var showSettings = false
    @State private var showImporter = false
    @State private var showIRImporter = false
    @State private var t3kBrowse: T3KBrowser.Target? = nil   // non-nil → present browser for that slot
    @State private var showManage = false
    @State private var showReorder = false
    private var isRunning: Bool { audio.state == .running }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                presetBar
                chainStrip
                editorPanel
                outputCard
                if let err = audio.lastError {
                    Text(err).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .onAppear { audio.applyCurrentPreset(); audio.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { if audio.state == .stopped { audio.start() } }
            else if phase == .background { audio.stop() }
        }
        .alert("Save preset", isPresented: $showSave) {
            TextField("Name", text: $newName)
            Button("Save") { audio.saveCurrent(as: newName); newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .sheet(isPresented: $showTuner) { tunerSheet }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showReorder) { reorderSheet }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "nam") ?? .data]) { result in
            if case .success(let url) = result { audio.importModel(from: url) }
        }
        .fileImporter(isPresented: $showIRImporter, allowedContentTypes: [.wav, .aiff, .audio]) { result in
            if case .success(let url) = result { audio.loadCabIR(from: url) }
        }
        .sheet(item: $t3kBrowse) { target in T3KBrowser(audio: audio, target: target) }
        .sheet(isPresented: $showManage) { manageSheet }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("NamRig").font(.title2.bold())
            Spacer()
            cpuBadge
            Button { showTuner = true } label: { Image(systemName: "tuningfork").font(.title3) }.buttonStyle(.plain)
            Button { showSettings = true } label: { Image(systemName: "gearshape").font(.title3) }.buttonStyle(.plain)
            Button(action: audio.toggle) {
                Image(systemName: isRunning ? "power.circle.fill" : "power.circle")
                    .font(.title2).foregroundStyle(isRunning ? .green : .secondary)
            }.buttonStyle(.plain)
        }
        .padding(.top, 12)
    }

    private var cpuBadge: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let pct = audio.cpuPercent
            let color: Color = pct > 80 ? .red : (pct > 50 ? .orange : .green)
            HStack(spacing: 3) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text("\(pct)%").font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(color)
            }
        }
    }

    // MARK: - Preset bar

    private var presetBar: some View {
        HStack(spacing: 10) {
            Button { audio.prevPreset() } label: { Image(systemName: "chevron.left.circle.fill").font(.title) }.buttonStyle(.plain)
            Spacer()
            VStack(spacing: 1) {
                Text(audio.currentPresetName)
                    .font(.system(size: 30, weight: .heavy, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                Text("PRESET \(audio.currentPresetIndex + 1)/\(audio.presets.count)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { audio.nextPreset() } label: { Image(systemName: "chevron.right.circle.fill").font(.title) }.buttonStyle(.plain)
            Menu {
                Button { showSave = true } label: { Label("Save as new…", systemImage: "plus") }
                Button { audio.overwriteCurrent() } label: { Label("Overwrite current", systemImage: "square.and.arrow.down") }
                Divider()
                ForEach(Array(audio.presets.enumerated()), id: \.element.id) { i, p in
                    Button(p.name) { audio.loadPreset(at: i) }
                }
            } label: { Image(systemName: "list.bullet").font(.title3) }
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Chain strip

    private var chainStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SIGNAL CHAIN").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button { showReorder = true } label: {
                    Label("Reorder", systemImage: "arrow.up.arrow.down").font(.caption.bold())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    endLabel("IN")
                    ForEach(audio.blockOrder.compactMap { ChainBlock($0) }) { block in
                        connector
                        tile(block)
                    }
                    connector
                    endLabel("OUT")
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func tile(_ block: ChainBlock) -> some View {
        let on = isOn(block), sel = selected == block
        return Button { selected = block } label: {
            VStack(spacing: 6) {
                Image(systemName: block.icon).font(.system(size: 20, weight: .semibold))
                Text(block.short).font(.system(size: 10, weight: .heavy))
            }
            .frame(width: 58, height: 74)
            .foregroundStyle(on ? .white : .white.opacity(0.3))
            .background(on ? block.color.gradient : Color.gray.opacity(0.22).gradient,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(sel ? .white : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func endLabel(_ t: String) -> some View {
        Text(t).font(.caption2.bold()).foregroundStyle(.secondary).frame(width: 26, height: 74)
    }
    private var connector: some View { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 6, height: 2) }

    // MARK: - Editor

    private var editorPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: selected.icon).foregroundStyle(isOn(selected) ? selected.color : .secondary)
                Text(selected.full).font(.headline)
                Spacer()
                Toggle("", isOn: enabled(selected)).labelsHidden().tint(.green)
            }
            controls(selected)
        }
        .padding().frame(maxWidth: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected.color.opacity(0.5), lineWidth: 1.5))
    }

    @ViewBuilder private func controls(_ b: ChainBlock) -> some View {
        switch b {
        case .gate:
            sliderRow("Threshold", value: $audio.gateThresholdDb, range: -70 ... -10)
        case .comp:
            sliderRow("Threshold", value: $audio.compThresholdDb, range: -48...0)
            sliderRow("Ratio", value: $audio.compRatio, range: 1...20, unit: ":1")
            sliderRow("Attack", value: $audio.compAttackMs, range: 1...100, unit: "ms")
            sliderRow("Release", value: $audio.compReleaseMs, range: 20...500, unit: "ms")
            sliderRow("Makeup", value: $audio.compMakeupDb, range: 0...24)
        case .boost:
            sliderRow("Boost", value: $audio.boostDb, range: 0...18)
        case .drive:
            Picker("Mode", selection: $audio.driveMode) { Text("Soft").tag(0); Text("Hard").tag(1); Text("Fuzz").tag(2) }
                .pickerStyle(.segmented)
            sliderRow("Drive", value: $audio.driveAmount, range: 1...50, unit: "x")
            sliderRow("Tone", value: $audio.driveToneHz, range: 1000...8000, unit: "Hz")
            sliderRow("Level", value: $audio.driveLevelDb, range: -24...6)
        case .amp:
            if let art = audio.selectedArtworkPath, let ui = UIImage(contentsOfFile: art) {
                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.25))
                    .frame(maxWidth: .infinity).frame(height: 150)
                    .overlay { Image(uiImage: ui).resizable().interpolation(.high).scaledToFit().padding(8) }   // whole image
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
                    .allowsHitTesting(false)   // decorative — never intercept the enable toggle
            }
            Menu {
                ForEach(audio.ampModels) { m in
                    Button { audio.selectedModelID = m.id } label: {
                        Label(m.name, systemImage: m.id == audio.selectedModelID ? "checkmark" : (m.bundled ? "shippingbox" : "tray.and.arrow.down"))
                    }
                }
                Divider()
                Button { showImporter = true } label: { Label("Import .nam…", systemImage: "square.and.arrow.down") }
                Button { t3kBrowse = .amp } label: { Label("Browse TONE3000…", systemImage: "magnifyingglass") }
                Button { showManage = true } label: { Label("Manage models…", systemImage: "folder") }
            } label: {
                HStack {
                    Image(systemName: "amplifier")
                    Text(audio.selectedModelName).fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            Text(audio.modelStatus).font(.caption).foregroundStyle(.secondary)
            sliderRow("Drive", value: $audio.inputDriveDb, range: 0...24)
            HStack(spacing: 8) {
                Image(systemName: "hifispeaker.fill").foregroundStyle(.secondary)
                Text(audio.cabIRName).font(.subheadline).lineLimit(1)
                Spacer()
                if audio.cabIRName != "None" {
                    Button { audio.clearCabIR() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Button { showIRImporter = true } label: { Label("Cab IR", systemImage: "square.and.arrow.down") }.font(.subheadline)
            }
            .padding(.vertical, 7).padding(.horizontal, 10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            TimelineView(.periodic(from: .now, by: 0.08)) { _ in
                VStack(spacing: 8) { meter("In", audio.inPeakDb); meter("Out", audio.outPeakDb) }
            }
        case .pedal:
            if let art = audio.selectedPedalArtworkPath, let ui = UIImage(contentsOfFile: art) {
                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.25))
                    .frame(maxWidth: .infinity).frame(height: 140)
                    .overlay { Image(uiImage: ui).resizable().interpolation(.high).scaledToFit().padding(8) }   // whole image
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
                    .allowsHitTesting(false)
            }
            Menu {
                Button { audio.selectedPedalModelID = nil } label: { Label("None (empty)", systemImage: audio.selectedPedalModelID == nil ? "checkmark" : "nosign") }
                ForEach(audio.pedalModels) { m in
                    Button { audio.selectedPedalModelID = m.id } label: {
                        Label(m.name, systemImage: m.id == audio.selectedPedalModelID ? "checkmark" : "tray.and.arrow.down")
                    }
                }
                Divider()
                Button { t3kBrowse = .pedal } label: { Label("Browse TONE3000 (Pedals)…", systemImage: "magnifyingglass") }
            } label: {
                HStack {
                    Image(systemName: "dial.low.fill")
                    Text(audio.selectedPedalName).fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            Text(audio.pedalStatus).font(.caption).foregroundStyle(.secondary)
            sliderRow("Drive", value: $audio.pedalDriveDb, range: 0...24)
            sliderRow("Level", value: $audio.pedalLevelDb, range: -24...12)
        case .eq:
            sliderRow("Bass", value: $audio.bassDb, range: -12...12)
            sliderRow("Mid", value: $audio.midDb, range: -12...12)
            sliderRow("Treble", value: $audio.trebleDb, range: -12...12)
        case .chorus:
            sliderRow("Rate", value: $audio.chorusRateHz, range: 0.1...8, unit: "Hz")
            sliderRow("Depth", value: $audio.chorusDepthMs, range: 1...15, unit: "ms")
            sliderRow("Mix", value: $audio.chorusMixPct, range: 0...100, unit: "%")
        case .flanger:
            sliderRow("Rate", value: $audio.flangerRateHz, range: 0.05...5, unit: "Hz")
            sliderRow("Depth", value: $audio.flangerDepthMs, range: 0.5...8, unit: "ms")
            sliderRow("Feedback", value: $audio.flangerFeedbackPct, range: 0...95, unit: "%")
            sliderRow("Mix", value: $audio.flangerMixPct, range: 0...100, unit: "%")
        case .tremolo:
            sliderRow("Rate", value: $audio.tremoloRateHz, range: 0.5...14, unit: "Hz")
            sliderRow("Depth", value: $audio.tremoloDepthPct, range: 0...100, unit: "%")
        case .delay:
            sliderRow("Time", value: $audio.delayTimeMs, range: 50...1000, unit: "ms")
            sliderRow("Feedback", value: $audio.delayFeedbackPct, range: 0...90, unit: "%")
            sliderRow("Mix", value: $audio.delayMixPct, range: 0...100, unit: "%")
        case .reverb:
            Picker("Type", selection: Binding(get: { audio.reverbType }, set: { audio.selectReverbType($0) })) {
                Text("Room").tag(0); Text("Plate").tag(1); Text("Spring").tag(2); Text("Hall").tag(3)
            }.pickerStyle(.segmented)
            sliderRow("Decay", value: $audio.reverbDecayPct, range: 0...100, unit: "%")
            sliderRow("Damping", value: $audio.reverbDampPct, range: 0...100, unit: "%")
            sliderRow("Mix", value: $audio.reverbMixPct, range: 0...100, unit: "%")
        }
    }

    private func isOn(_ b: ChainBlock) -> Bool {
        switch b {
        case .gate: return audio.gateEnabled; case .comp: return audio.compEnabled; case .boost: return audio.boostEnabled
        case .drive: return audio.driveEnabled; case .pedal: return audio.pedalEnabled; case .amp: return audio.ampEnabled; case .eq: return audio.eqEnabled
        case .chorus: return audio.chorusEnabled; case .flanger: return audio.flangerEnabled; case .tremolo: return audio.tremoloEnabled
        case .delay: return audio.delayEnabled; case .reverb: return audio.reverbEnabled
        }
    }
    private func enabled(_ b: ChainBlock) -> Binding<Bool> {
        switch b {
        case .gate: return $audio.gateEnabled; case .comp: return $audio.compEnabled; case .boost: return $audio.boostEnabled
        case .drive: return $audio.driveEnabled; case .pedal: return $audio.pedalEnabled; case .amp: return $audio.ampEnabled; case .eq: return $audio.eqEnabled
        case .chorus: return $audio.chorusEnabled; case .flanger: return $audio.flangerEnabled; case .tremolo: return $audio.tremoloEnabled
        case .delay: return $audio.delayEnabled; case .reverb: return $audio.reverbEnabled
        }
    }

    private var reorderSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(audio.blockOrder, id: \.self) { kind in
                        if let cb = ChainBlock(kind) {
                            HStack(spacing: 12) {
                                Image(systemName: cb.icon).foregroundStyle(isOn(cb) ? cb.color : .secondary).frame(width: 24)
                                Text(cb.full)
                                Spacer()
                                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onMove { from, to in var o = audio.blockOrder; o.move(fromOffsets: from, toOffset: to); audio.setOrder(o) }
                } footer: {
                    Text("Drag to reorder the chain. Signal flows top → bottom (IN → OUT).")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Chain Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showReorder = false } } }
        }
    }

    private var outputCard: some View {
        card { sliderRow("Output", value: $audio.outputLevelDb, range: -40...12) }
    }

    // MARK: - Tuner sheet

    private var tunerSheet: some View {
        let active = audio.tunerActive, cents = audio.tunerCents
        let inTune = active && abs(cents) <= 5
        return NavigationStack {
            VStack(spacing: 18) {
                Spacer()
                Text(active ? audio.tunerNote : "—")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(inTune ? .green : .primary)
                GeometryReader { geo in
                    let mid = geo.size.width / 2, h = geo.size.height
                    let clamped = CGFloat(max(-50, min(50, cents))) / 50
                    ZStack {
                        Capsule().fill(.black.opacity(0.2)).frame(height: 6).position(x: mid, y: h / 2)
                        Rectangle().fill(.secondary).frame(width: 2, height: 26).position(x: mid, y: h / 2)
                        if active {
                            Circle().fill(inTune ? Color.green : .orange)
                                .frame(width: 22, height: 22).position(x: mid + clamped * (mid - 16), y: h / 2)
                        }
                    }
                }
                .frame(height: 36).padding(.horizontal, 30)
                Text(active ? "\(cents > 0 ? "+" : "")\(cents)¢" : (isRunning ? "play a single note" : "engine off"))
                    .font(.headline).monospacedDigit().foregroundStyle(inTune ? .green : .secondary)
                Spacer()
            }
            .navigationTitle("Tuner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showTuner = false } } }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Settings sheet (metrics)

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("TONE3000") {
                    if let token = UserDefaults.standard.string(forKey: "t3k_token") {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button { UIPasteboard.general.string = token } label: { Label("Copy access token", systemImage: "doc.on.doc") }
                    } else {
                        Text("Not connected. Use Amp → Browse TONE3000 to log in.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Audio") {
                    row("Sample rate", audio.sampleRate > 0 ? "\(Int(audio.sampleRate)) Hz" : "—")
                    row("Input / Output", audio.inputSampleRate > 0 ? "\(Int(audio.inputSampleRate)) / \(Int(audio.outputSampleRate)) Hz" : "—")
                    row("I/O buffer", fmt(audio.ioBufferMs))
                    row("Round-trip (buffer)", fmt(audio.roundTripMs))
                    Picker("Latency / stability", selection: $audio.preferredBufferFrames) {
                        Text("Low · 128").tag(128.0)
                        Text("Balanced · 256").tag(256.0)
                        Text("Safe · 512").tag(512.0)
                    }
                    row("OS-reported I/O", fmt(audio.reportedLatencyMs))
                }
                Section("Performance") {
                    TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                        let pct = audio.cpuPercent
                        let color: Color = pct > 80 ? .red : (pct > 50 ? .orange : .green)
                        VStack(spacing: 4) {
                            HStack { Text("CPU (DSP load)"); Spacer(); Text("\(pct)%").bold().monospacedDigit().foregroundStyle(color) }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.black.opacity(0.2))
                                    Capsule().fill(color).frame(width: geo.size.width * min(1, Double(pct) / 100))
                                }
                            }.frame(height: 8)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var manageSheet: some View {
        NavigationStack {
            List {
                Section("Downloaded / imported") {
                    let downloaded = audio.models.filter { !$0.bundled }
                    if downloaded.isEmpty {
                        Text("None yet — import a .nam or download from TONE3000.").foregroundStyle(.secondary)
                    }
                    ForEach(downloaded) { m in Text(m.name) }
                        .onDelete { idx in
                            let list = audio.models.filter { !$0.bundled }
                            for i in idx where list.indices.contains(i) { audio.deleteModel(id: list[i].id) }
                        }
                }
                Section("Built-in") {
                    ForEach(audio.models.filter { $0.bundled }) { m in
                        Text(m.name).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showManage = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Pieces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) { content() }
            .padding().frame(maxWidth: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func meter(_ label: String, _ db: Float) -> some View {
        let norm = max(0, min(1, (Double(db) + 60) / 60))
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(db <= -120 ? "—" : String(format: "%.0f dB", db)).font(.caption).monospacedDigit()
            }
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.25))
                Rectangle().fill(db > -1 ? Color.red : Color.green)
                    .scaleEffect(x: CGFloat(norm), anchor: .leading)   // transform, not layout — no GeometryReader thrash
            }
            .frame(height: 8)
            .clipShape(Capsule())
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String = "dB") -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(unit)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func fmt(_ ms: Double) -> String { ms > 0 ? String(format: "%.1f ms", ms) : "—" }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit().fontWeight(.semibold) }
    }
}

#Preview { ContentView() }
