//
//  ContentView.swift
//  NamRig — modeler UI: preset brain, chain strip, per-block editor.
//  Tuner + metrics live in pop-up sheets to keep the main screen clean.
//

import SwiftUI
import UniformTypeIdentifiers

enum ChainBlock: String, CaseIterable, Identifiable {
    case gate, comp, boost, drive, stomp, wah, pedal, amp, cab, eq, chorus, flanger, tremolo, delay, reverb, irReverb
    var id: String { rawValue }

    var kind: BlockKind {
        switch self {
        case .gate: return .gate; case .comp: return .comp; case .boost: return .boost; case .drive: return .drive; case .stomp: return .stomp; case .wah: return .wah
        case .pedal: return .pedal; case .amp: return .amp; case .cab: return .cab; case .eq: return .eq
        case .chorus: return .chorus; case .flanger: return .flanger; case .tremolo: return .tremolo
        case .delay: return .delay; case .reverb: return .reverb; case .irReverb: return .irReverb
        }
    }
    init?(_ k: BlockKind) {
        switch k {
        case .gate: self = .gate; case .comp: self = .comp; case .boost: self = .boost; case .drive: self = .drive; case .stomp: self = .stomp; case .wah: self = .wah
        case .pedal: self = .pedal; case .amp: self = .amp; case .cab: self = .cab; case .eq: self = .eq
        case .chorus: self = .chorus; case .flanger: self = .flanger; case .tremolo: self = .tremolo
        case .delay: self = .delay; case .reverb: self = .reverb; case .irReverb: self = .irReverb
        }
    }

    var short: String {
        switch self {
        case .gate: return "GATE"; case .comp: return "COMP"; case .boost: return "BST"; case .drive: return "DRV"; case .stomp: return "STMP"; case .wah: return "WAH"
        case .pedal: return "PED"; case .amp: return "AMP"; case .cab: return "CAB"; case .eq: return "EQ"; case .chorus: return "CHO"; case .flanger: return "FLG"
        case .tremolo: return "TRM"; case .delay: return "DLY"; case .reverb: return "RVB"; case .irReverb: return "IRV"
        }
    }
    var full: String {
        switch self {
        case .gate: return "Noise Gate"; case .comp: return "Compressor"; case .boost: return "Clean Boost"; case .drive: return "Drive"; case .stomp: return "Stompbox"; case .wah: return "Wah"
        case .pedal: return "Pedal"; case .amp: return "Amp"; case .cab: return "Cab"; case .eq: return "EQ"; case .chorus: return "Chorus"; case .flanger: return "Flanger"
        case .tremolo: return "Tremolo"; case .delay: return "Delay"; case .reverb: return "Reverb"; case .irReverb: return "IR Reverb"
        }
    }
    var icon: String {
        switch self {
        case .gate: return "waveform.path.ecg"; case .comp: return "dial.medium"; case .boost: return "bolt.fill"; case .drive: return "flame.fill"; case .stomp: return "flame.circle.fill"; case .wah: return "dial.min.fill"
        case .pedal: return "dial.low.fill"; case .amp: return "amplifier"; case .cab: return "hifispeaker.fill"; case .eq: return "slider.vertical.3"; case .chorus: return "water.waves"; case .flanger: return "wind"
        case .tremolo: return "metronome"; case .delay: return "timer"; case .reverb: return "drop.fill"; case .irReverb: return "square.stack.3d.down.right.fill"
        }
    }
    var color: Color {
        switch self {
        case .gate: return .teal; case .comp: return .blue; case .boost: return .yellow; case .drive: return .orange; case .stomp: return Color(red: 0.85, green: 0.3, blue: 0.1); case .wah: return Color(red: 0.55, green: 0.35, blue: 0.9)
        case .pedal: return .brown; case .amp: return .red; case .cab: return Color(red: 0.62, green: 0.42, blue: 0.24); case .eq: return .green; case .chorus: return .mint; case .flanger: return .indigo
        case .tremolo: return .pink; case .delay: return .purple; case .reverb: return .cyan; case .irReverb: return .cyan
        }
    }
}

struct ContentView: View {
    @State private var audio = AudioEngine()
    @State private var selectedID: UUID? = nil        // selected block INSTANCE (nil → no editor)
    @State private var outputSelected = false        // the OUTPUT block's editor (master + stereo)
    @State private var looperSelected = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSave = false
    @State private var newName = ""
    @State private var showTuner = false
    @State private var showSettings = false
    @AppStorage("uiAppearance") private var uiAppearance = 0   // 0 system · 1 light · 2 dark
    @State private var showImporter = false
    @State private var showIRImporter = false
    @State private var showRevIRImporter = false
    @State private var t3kBrowse: T3KBrowser.Target? = nil   // non-nil → present browser for that slot
    @State private var showManage = false
    @State private var showReorder = false
    @State private var showLive = false
    @State private var showMIDI = false
    @State private var showBLE = false
    @State private var showPresets = false
    @State private var renameIdx: Int? = nil
    @State private var renameText = ""
    @State private var mutedBeforeTuner = false
    @State private var midi = MIDIManager()
    private var isRunning: Bool { audio.state == .running }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                SignalStrip(audio: audio).frame(maxWidth: .infinity, alignment: .leading)
                presetBar
                chainStrip
                if let sid = selectedID, let found = audio.instance(sid), let cb = ChainBlock(found.inst.kind) { editorPanel(cb, sid, found.path) }
                else if outputSelected { outputEditorPanel }
                else if looperSelected { looperPanel }
                if let err = audio.lastError {
                    Text(err).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .onAppear { audio.applyCurrentPreset(); audio.start(); midi.start(engine: audio) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { if audio.state == .stopped { audio.start() } }
            else if phase == .background { audio.stop() }
        }
        .onChange(of: audio.tunerRequested) { _, on in showTuner = on }
        .onChange(of: showTuner) { _, on in if !on { audio.tunerRequested = false } }
        .alert("Save preset", isPresented: $showSave) {
            TextField("Name", text: $newName)
            Button("Save") { audio.saveCurrent(as: newName); newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .sheet(isPresented: $showTuner) {
            tunerSheet
                .onAppear { mutedBeforeTuner = audio.muted; audio.muted = true }
                .onDisappear { audio.muted = mutedBeforeTuner }
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showReorder) { reorderSheet }
        .sheet(isPresented: $showMIDI) { midiSheet }
        .fullScreen(isPresented: $showLive) {
            LiveView(audio: audio, onExit: { showLive = false }, onTuner: { showLive = false; showTuner = true })
                .preferredColorScheme(uiAppearance == 1 ? .light : uiAppearance == 2 ? .dark : nil)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "nam") ?? .data]) { result in
            if case .success(let url) = result { audio.importModel(from: url) }
        }
        .fileImporter(isPresented: $showIRImporter, allowedContentTypes: [.wav, .aiff, .audio]) { result in
            if case .success(let url) = result { audio.loadCabIR(from: url) }
        }
        .sheet(item: $t3kBrowse) { target in T3KBrowser(audio: audio, target: target) }
        .sheet(isPresented: $showManage) { manageSheet }
        .sheet(isPresented: $showPresets) { presetManageSheet }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("NamRig").font(.title2.bold())
            Spacer()
            Button { showLive = true } label: {
                Label("Live", systemImage: "tv").font(.subheadline.bold())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.tint.opacity(0.18), in: Capsule())
            }.buttonStyle(.plain)
            Button { showTuner = true } label: { Image(systemName: "tuningfork").font(.title3) }.buttonStyle(.plain)
            Button { showMIDI = true } label: {
                Image(systemName: "pianokeys").font(.title3)
                    .overlay(alignment: .topTrailing) {
                        if midi.lastActivity > 0 { Circle().fill(.green).frame(width: 6, height: 6).offset(x: 3, y: -3) }
                    }
            }.buttonStyle(.plain)
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
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text(audio.presetTag)
                        .font(.system(size: 19, weight: .black, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 2)
                        .background(sceneColor(audio.sceneInBank), in: RoundedRectangle(cornerRadius: 7))
                    Text(audio.currentPresetName)
                        .font(.system(size: 27, weight: .heavy, design: .rounded)).lineLimit(1).minimumScaleFactor(0.5)
                }
                Text("PRESET \(audio.currentPresetIndex + 1)/\(audio.presets.count)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { audio.nextPreset() } label: { Image(systemName: "chevron.right.circle.fill").font(.title) }.buttonStyle(.plain)
            Menu {
                Button { showPresets = true } label: { Label("Setlist / Manage…", systemImage: "music.note.list") }
                Divider()
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

    // MARK: - Chain strip (ChainStrip.swift)

    private var chainStrip: some View {
        ChainStripView(audio: audio, selectedID: $selectedID, outputSelected: $outputSelected, looperSelected: $looperSelected, showReorder: $showReorder)
    }

    // MARK: - Editor

    private func editorPanel(_ block: ChainBlock, _ iid: UUID, _ path: RigPathID) -> some View {
        VStack(spacing: 12) {
            HStack {
                if audio.dualOn {
                    Text(path.label).font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Color.cyan, in: Capsule())
                }
                Image(systemName: block.icon).foregroundStyle(isOn(block) ? block.color : .secondary)
                Text(audio.label(for: iid, in: path).map { "\(block.full) \($0)" } ?? block.full).font(.headline)
                Spacer()
                if audio.dualOn && audio.availableToAdd(in: path.other).contains(block.kind) {
                    Button { let to = path.other; audio.moveInstance(iid, from: path, to: to, before: nil); audio.focusInstance(iid, in: to) } label: {
                        Label("→ \(path.other.label)", systemImage: "arrow.turn.down.right").font(.caption.bold())
                    }.buttonStyle(.bordered).controlSize(.small)
                }
                Button { audio.removeInstance(iid, in: path); selectedID = nil } label: { Image(systemName: "trash").font(.subheadline) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Toggle("", isOn: enabled(block)).labelsHidden().tint(.green)
            }
            controls(block)
        }
        .padding().frame(maxWidth: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(block.color.opacity(0.5), lineWidth: 1.5))
    }

    @ViewBuilder private func controls(_ b: ChainBlock) -> some View {
        let c = b.color
        switch b {
        case .gate:
            KnobGrid {
                Knob(label: "Threshold", value: $audio.gateThresholdDb, range: -70 ... -10, unit: "dB", color: c, defaultValue: -40)
                Knob(label: "Release", value: $audio.gateReleaseMs, range: 10...500, unit: "ms", color: c, defaultValue: 80)
                Knob(label: "Range", value: $audio.gateRangeDb, range: -90 ... -10, unit: "dB", color: c, defaultValue: -80)
            }
            Text("Range sets how far the gate closes: −90 dB = hard mute, −20 dB = gentle expander (hiss down, sustain intact).")
                .font(.caption2).foregroundStyle(.secondary)
        case .comp:
            KnobGrid {
                Knob(label: "Thresh", value: $audio.compThresholdDb, range: -48...0, unit: "dB", color: c, defaultValue: -18)
                Knob(label: "Ratio", value: $audio.compRatio, range: 1...20, unit: ":1", decimals: 1, color: c, defaultValue: 4)
                Knob(label: "Attack", value: $audio.compAttackMs, range: 1...100, unit: "ms", color: c, defaultValue: 10)
                Knob(label: "Release", value: $audio.compReleaseMs, range: 20...500, unit: "ms", color: c, defaultValue: 120)
                Knob(label: "Makeup", value: $audio.compMakeupDb, range: 0...24, unit: "dB", color: c, defaultValue: 0)
            }
            TimelineView(.periodic(from: .now, by: 0.08)) { _ in grMeter(audio.compGainReductionDb) }
        case .boost:
            KnobGrid { Knob(label: "Boost", value: $audio.boostDb, range: 0...18, unit: "dB", color: c, defaultValue: 6) }
        case .drive:
            Picker("Mode", selection: $audio.driveMode) { Text("Soft").tag(0); Text("Hard").tag(1); Text("Fuzz").tag(2) }
                .pickerStyle(.segmented)
            KnobGrid {
                Knob(label: "Drive", value: $audio.driveAmount, range: 1...50, unit: "x", color: c, defaultValue: 4)
                Knob(label: "Tone", value: $audio.driveToneHz, range: 1000...8000, unit: "Hz", color: c, defaultValue: 4000)
                Knob(label: "Level", value: $audio.driveLevelDb, range: -24...6, unit: "dB", color: c, defaultValue: 0)
            }
        case .stomp:
            Picker("Pedal", selection: $audio.stompModel) {
                ForEach(0..<audio.stompModelCount, id: \.self) { i in Text(audio.stompModelName(i)).tag(i) }
            }
            .pickerStyle(.menu)
            KnobGrid {
                Knob(label: "Drive", value: $audio.stompDrive, range: 0...1, unit: "", decimals: 2, color: c, defaultValue: 0.5)
                Knob(label: "Tone", value: $audio.stompTone, range: 0...1, unit: "", decimals: 2, color: c, defaultValue: 0.5)
                Knob(label: "Level", value: $audio.stompLevel, range: 0...1, unit: "", decimals: 2, color: c, defaultValue: 0.8)
            }
            Text(CircuitDriveBlock.disclaimer).font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
        case .wah:
            Picker("Mode", selection: $audio.wahAuto) { Text("Pedal").tag(false); Text("Auto").tag(true) }.pickerStyle(.segmented)
            KnobGrid {
                if audio.wahAuto {
                    Knob(label: "Sense", value: $audio.wahSense, range: 0...100, unit: "%", color: c, defaultValue: 50)
                } else {
                    Knob(label: "Pedal", value: $audio.wahPosition, range: 0...1, unit: "", decimals: 2, color: c, defaultValue: 0.5)
                }
                Knob(label: "Mix", value: $audio.wahMix, range: 0...100, unit: "%", color: c, defaultValue: 92)
            }
            if !audio.wahAuto {
                Slider(value: $audio.wahPosition, in: 0...1) { Text("Pedal") } minimumValueLabel: { Text("heel").font(.caption2) } maximumValueLabel: { Text("toe").font(.caption2) }
                    .tint(c)
                Text("Expression pedal: MIDI → Add mapping → Parameter → \"Wah (expression)\", then Learn.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .amp:
            if let art = audio.selectedArtworkPath, let img = Image(file: art) {
                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.25))
                    .frame(maxWidth: .infinity).frame(height: 150)
                    .overlay { img.resizable().interpolation(.high).scaledToFit().padding(8) }   // whole image
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
            HStack(alignment: .top, spacing: 14) {
                Knob(label: "Drive", value: $audio.inputDriveDb, range: 0...24, unit: "dB", color: c, defaultValue: 0, size: 72)
                TimelineView(.periodic(from: .now, by: 0.08)) { _ in
                    VStack(spacing: 8) { meter("In", audio.inPeakDb); meter("Out", audio.outPeakDb) }
                }
            }
        case .pedal:
            if let art = audio.selectedPedalArtworkPath, let img = Image(file: art) {
                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.25))
                    .frame(maxWidth: .infinity).frame(height: 140)
                    .overlay { img.resizable().interpolation(.high).scaledToFit().padding(8) }   // whole image
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
            KnobGrid {
                Knob(label: "Drive", value: $audio.pedalDriveDb, range: 0...24, unit: "dB", color: c, defaultValue: 0)
                Knob(label: "Level", value: $audio.pedalLevelDb, range: -24...12, unit: "dB", color: c, defaultValue: 0)
            }
        case .eq:
            KnobGrid {
                Knob(label: "Bass", value: $audio.bassDb, range: -12...12, unit: "dB", color: c, defaultValue: 0, bipolar: true)
                Knob(label: "Mid", value: $audio.midDb, range: -12...12, unit: "dB", color: c, defaultValue: 0, bipolar: true)
                Knob(label: "Treble", value: $audio.trebleDb, range: -12...12, unit: "dB", color: c, defaultValue: 0, bipolar: true)
            }
        case .chorus:
            KnobGrid {
                Knob(label: "Rate", value: $audio.chorusRateHz, range: 0.1...8, unit: "Hz", decimals: 2, color: c, defaultValue: 0.8)
                Knob(label: "Depth", value: $audio.chorusDepthMs, range: 1...15, unit: "ms", decimals: 1, color: c, defaultValue: 6)
                Knob(label: "Mix", value: $audio.chorusMixPct, range: 0...100, unit: "%", color: c, defaultValue: 40)
            }
        case .flanger:
            KnobGrid {
                Knob(label: "Rate", value: $audio.flangerRateHz, range: 0.05...5, unit: "Hz", decimals: 2, color: c, defaultValue: 0.4)
                Knob(label: "Depth", value: $audio.flangerDepthMs, range: 0.5...8, unit: "ms", decimals: 1, color: c, defaultValue: 2)
                Knob(label: "Feedback", value: $audio.flangerFeedbackPct, range: 0...95, unit: "%", color: c, defaultValue: 50)
                Knob(label: "Mix", value: $audio.flangerMixPct, range: 0...100, unit: "%", color: c, defaultValue: 50)
            }
        case .tremolo:
            KnobGrid {
                Knob(label: "Rate", value: $audio.tremoloRateHz, range: 0.5...14, unit: "Hz", decimals: 1, color: c, defaultValue: 5)
                Knob(label: "Depth", value: $audio.tremoloDepthPct, range: 0...100, unit: "%", color: c, defaultValue: 50)
            }
        case .cab:
            HStack(spacing: 8) {
                Image(systemName: "hifispeaker.fill").foregroundStyle(.secondary)
                Text(audio.cabIRName).font(.subheadline).lineLimit(1)
                Spacer()
                if audio.cabIRName != "None" {
                    Button { audio.clearCabIR() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Button { t3kBrowse = .cab } label: { Label("Browse", systemImage: "magnifyingglass") }.font(.subheadline)
                Button { showIRImporter = true } label: { Label("File", systemImage: "square.and.arrow.down") }.font(.subheadline)
            }
            Text("Speaker cabinet IR. Browse TONE3000 cabs or load your own .wav / .aiff.")
                .font(.caption2).foregroundStyle(.secondary)
        case .delay:
            Toggle("Tempo Sync", isOn: $audio.delaySync).tint(.purple).font(.subheadline)
            if audio.delaySync {
                HStack {
                    Button { audio.tapTempo() } label: { Label("TAP", systemImage: "hand.tap.fill") }
                        .buttonStyle(.borderedProminent).tint(.purple)
                    Spacer()
                    Text("\(audio.tempo.bpmRounded) BPM").font(.headline.monospacedDigit())
                }
                Picker("Division", selection: $audio.delayDivision) {
                    ForEach(TempoClock.NoteDivision.allCases) { d in Text(d.displayName).tag(d) }
                }.pickerStyle(.segmented)
            }
            KnobGrid {
                if !audio.delaySync { Knob(label: "Time", value: $audio.delayTimeMs, range: 50...1000, unit: "ms", color: c, defaultValue: 350) }
                Knob(label: "Feedback", value: $audio.delayFeedbackPct, range: 0...90, unit: "%", color: c, defaultValue: 35)
                Knob(label: "Tone", value: $audio.delayTonePct, range: 0...100, unit: "%", color: c, defaultValue: 60)
                Knob(label: "Mix", value: $audio.delayMixPct, range: 0...100, unit: "%", color: c, defaultValue: 30)
            }
        case .reverb:
            Picker("Type", selection: Binding(get: { audio.reverbType }, set: { audio.selectReverbType($0) })) {
                Text("Room").tag(0); Text("Plate").tag(1); Text("Spring").tag(2); Text("Hall").tag(3)
            }.pickerStyle(.segmented)
            KnobGrid {
                Knob(label: "Decay", value: $audio.reverbDecayPct, range: 0...100, unit: "%", color: c, defaultValue: 70)
                Knob(label: "Damping", value: $audio.reverbDampPct, range: 0...100, unit: "%", color: c, defaultValue: 30)
                Knob(label: "Mix", value: $audio.reverbMixPct, range: 0...100, unit: "%", color: c, defaultValue: 25)
            }
        case .irReverb:
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.down.right.fill").foregroundStyle(.secondary)
                Text(audio.irReverbName).font(.subheadline).lineLimit(1)
                Spacer()
                if audio.irReverbName != "None" {
                    Button { audio.clearReverbIR() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Button { showRevIRImporter = true } label: { Label("Load IR", systemImage: "square.and.arrow.down") }.font(.subheadline)
            }
            .padding(.vertical, 7).padding(.horizontal, 10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            KnobGrid {
                Knob(label: "Predelay", value: $audio.irReverbPredelayMs, range: 0...200, unit: "ms", color: c, defaultValue: 0)
                Knob(label: "Mix", value: $audio.irReverbMixPct, range: 0...100, unit: "%", color: c, defaultValue: 35)
            }
        }
    }

    private func grMeter(_ gr: Float) -> some View {
        let norm = max(0, min(1, Double(-gr) / 24))
        return HStack(spacing: 8) {
            Text("GR").font(.caption2.bold()).foregroundStyle(.secondary)
            ZStack(alignment: .trailing) {
                Capsule().fill(.black.opacity(0.25))
                Rectangle().fill(Color.orange).scaleEffect(x: CGFloat(norm), anchor: .trailing)
            }.frame(height: 6).clipShape(Capsule())
            Text(String(format: "%.1f dB", gr)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
        }
    }

    private func isOn(_ b: ChainBlock) -> Bool { audio.isBlockEnabled(b.kind) }
    private func enabled(_ b: ChainBlock) -> Binding<Bool> {
        Binding(get: { audio.isBlockEnabled(b.kind) }, set: { audio.setBlockEnabled(b.kind, $0) })
    }

    private var reorderSheet: some View {
        let path = audio.focus
        return NavigationStack {
            List {
                Section {
                    ForEach(audio.instances(of: path)) { inst in
                        if let cb = ChainBlock(inst.kind) {
                            HStack(spacing: 12) {
                                Image(systemName: cb.icon).foregroundStyle(audio.isEnabled(inst.id, in: path) ? cb.color : .secondary).frame(width: 24)
                                Text(audio.label(for: inst.id, in: path).map { "\(cb.full) \($0)" } ?? cb.full)
                                Spacer()
                                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onMove { from, to in var ids = audio.instances(of: path).map(\.id); ids.move(fromOffsets: from, toOffset: to); audio.reorder(ids, in: path) }
                    .onDelete { idx in let ids = idx.map { audio.instances(of: path)[$0].id }; for i in ids { audio.removeInstance(i, in: path) } }
                } footer: {
                    Text("Drag to reorder the chain. Signal flows top → bottom (IN → OUT). Any block can appear more than once.")
                }
            }
            .alwaysEditing()
            .navigationTitle(audio.dualOn ? "Chain Order · Path \(path.label)" : "Chain Order")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showReorder = false } } }
        }
    }

    private var outputEditorPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.cyan)
                Text("Output / Mixer").font(.headline)
                Spacer()
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.tertiary)
            }
            HStack(alignment: .top, spacing: 14) {
                Knob(label: "Master", value: $audio.outputLevelDb, range: -40...12, unit: "dB", color: .cyan, defaultValue: -6, size: 72)
                TimelineView(.periodic(from: .now, by: 0.08)) { _ in
                    VStack(spacing: 8) { meter("Out", audio.outPeakDb) }
                }
            }
            Divider().overlay(.secondary.opacity(0.2))
            Toggle(isOn: $audio.stereoOn) {
                Label("Stereo Width", systemImage: "speaker.wave.3.fill").font(.subheadline.bold())
            }
            .tint(.cyan)
            if audio.stereoOn {
                KnobGrid {
                    Knob(label: "Width", value: $audio.stereoWidth, range: 0...100, unit: "%", color: .cyan, defaultValue: 100)
                    Knob(label: "Ping-Pong", value: $audio.stereoPingMix, range: 0...100, unit: "%", color: .cyan, defaultValue: 25)
                    Knob(label: "Echo", value: $audio.stereoPingTime, range: 50...700, unit: "ms", color: .cyan, defaultValue: 350)
                    Knob(label: "Feedback", value: $audio.stereoPingFb, range: 0...85, unit: "%", color: .cyan, defaultValue: 30)
                    Knob(label: "Ambience", value: $audio.stereoSpace, range: 0...100, unit: "%", color: .cyan, defaultValue: 18)
                }
                Text("Mono chain → wide stereo out. Needs headphones or stereo monitors to hear.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Divider().overlay(.secondary.opacity(0.2))
            Toggle(isOn: $audio.dualOn) {
                Label("Dual path  A ∥ B", systemImage: "rectangle.split.1x2").font(.subheadline.bold())
            }
            .tint(.cyan)
            if audio.dualOn {
                KnobGrid {
                    Knob(label: "Level A", value: $audio.pathALevelDb, range: -24...12, unit: "dB", color: .cyan, defaultValue: 0)
                    Knob(label: "Pan A", value: $audio.pathAPan, range: -1...1, unit: "", decimals: 2, color: .cyan, defaultValue: -0.7, bipolar: true)
                    Knob(label: "Level B", value: $audio.pathBLevelDb, range: -24...12, unit: "dB", color: .cyan, defaultValue: 0)
                    Knob(label: "Pan B", value: $audio.pathBPan, range: -1...1, unit: "", decimals: 2, color: .cyan, defaultValue: 0.7, bipolar: true)
                }
                Text("Both paths get the guitar; each is a complete chain. Drag tiles between the A and B rows. ~2× CPU.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Divider().overlay(.secondary.opacity(0.2))
            midiOutSection
        }
        .padding().frame(maxWidth: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.25)))
    }

    private var looperPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "repeat.circle.fill").foregroundStyle(.green)
                Text("Looper").font(.headline)
                Spacer()
                Text(audio.looperStateLabel).font(.caption.bold().monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button { audio.toggleLooper() } label: {
                    Label(looperButtonText, systemImage: looperButtonIcon).frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.green)
                Button { audio.stopLooper() } label: { Image(systemName: "stop.fill") }.buttonStyle(.bordered)
                Button { audio.clearLooper() } label: { Image(systemName: "trash") }.buttonStyle(.bordered).tint(.red)
            }
            KnobGrid { Knob(label: "Loop Level", value: $audio.loopLevel, range: 0...100, unit: "%", color: .green, defaultValue: 100) }
            Text("Records the full rig (after both paths). One button: Record → Play → Overdub. Map a footswitch in MIDI.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding().frame(maxWidth: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.green.opacity(0.5), lineWidth: 1.5))
    }

    private var looperButtonText: String {
        switch audio.looperStateLabel {
        case "REC": return "Stop & Play"
        case "Play": return "Overdub"
        case "Overdub": return "Stop Dub"
        case "Stopped": return "Play"
        default: return audio.looperHasLoop ? "Play" : "Record"
        }
    }
    private var looperButtonIcon: String {
        switch audio.looperStateLabel {
        case "REC": return "stop.circle.fill"
        case "Play", "Overdub": return "plus.circle.fill"
        case "Stopped": return "play.fill"
        default: return audio.looperHasLoop ? "play.fill" : "record.circle.fill"
        }
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
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showTuner = false } } }
        }
        .sheetSize([.medium], mac: CGSize(width: 420, height: 320))
    }

    // MARK: - Settings sheet (metrics)

    private var midiSheet: some View {
        NavigationStack {
            Form {
                Section("Devices") {
                    if midi.sources.isEmpty {
                        Label("No MIDI inputs connected", systemImage: "pianokeys").foregroundStyle(.secondary)
                    } else {
                        ForEach(midi.sources, id: \.self) { Label($0, systemImage: "pianokeys.inverse") }
                    }
                    #if os(iOS)
                    Button { showBLE = true } label: { Label("Bluetooth MIDI…", systemImage: "antenna.radiowaves.left.and.right") }
                    #else
                    Text("Bluetooth MIDI pedals: pair them in Audio MIDI Setup → Window → Show MIDI Studio → Bluetooth.").font(.caption).foregroundStyle(.secondary)
                    #endif
                    HStack {
                        Text("Last received").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(midi.lastMessage).font(.caption.monospacedDigit()).foregroundStyle(midi.lastActivity > 0 ? .green : .secondary)
                    }
                    if let bpm = midi.externalClockBpm {
                        HStack { Text("External clock").font(.caption).foregroundStyle(.secondary); Spacer(); Text("\(Int(bpm.rounded())) BPM").font(.caption.monospacedDigit()) }
                    }
                }
                Section("Input") {
                    Picker("Listen on channel", selection: Binding(get: { midi.channelFilter ?? 0 }, set: { midi.channelFilter = $0 == 0 ? nil : $0 })) {
                        Text("Omni").tag(0)
                        ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Toggle("Bank Select (CC0/32) + PC", isOn: $midi.bankSelect)
                    Toggle("Follow MIDI clock (tempo)", isOn: $midi.clockInSync)
                    Picker("Knob / switch mappings act on", selection: Binding(get: { audio.midiPath?.rawValue ?? "focus" }, set: { audio.midiPath = RigPathID(rawValue: $0) })) {
                        Text("Path A").tag("a"); Text("Path B").tag("b"); Text("Selected path").tag("focus")
                    }
                    Text("Program Change selects preset 1–\(max(audio.presets.count, 1)).").font(.caption).foregroundStyle(.secondary)
                }
                Section("Output") {
                    if midi.destinations.isEmpty {
                        Text("No hardware outputs. \"NamRig Out\" virtual port is always available to other apps.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(midi.destinations, id: \.self) { Label($0, systemImage: "arrow.up.right.circle") }
                    }
                    Picker("Send on channel", selection: $midi.outChannel) { ForEach(1...16, id: \.self) { Text("\($0)").tag($0) } }
                    Toggle("Program Change on preset load", isOn: $midi.sendPCOnPresetLoad)
                    Toggle("CC feedback (knob → controller)", isOn: $midi.sendCCFeedback)
                    Toggle("Send MIDI clock (tap tempo)", isOn: $midi.sendClock)
                    HStack { Text("Last sent").font(.caption).foregroundStyle(.secondary); Spacer(); Text(midi.lastSent).font(.caption.monospacedDigit()) }
                    Text("Per-preset messages to external gear are edited in the OUT block → MIDI Out.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Mappings") {
                    if midi.mappings.isEmpty {
                        Text("No mappings yet. Add one, then press a footswitch / move a pedal to learn it.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach($midi.mappings) { $m in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(m.target.label).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(m.source == .note ? "Note \(m.cc)" : "CC \(m.cc)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            HStack {
                                Stepper("", value: $m.cc, in: 0...127).labelsHidden()
                                if m.target.isSwitch {
                                    Picker("", selection: $m.momentary) { Text("Press").tag(true); Text("Latch").tag(false) }
                                        .pickerStyle(.segmented).frame(width: 130)
                                }
                                Spacer()
                                Button { midi.beginLearn(m.id) } label: { Label("Learn", systemImage: "dot.radiowaves.left.and.right") }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { idx in idx.map { midi.mappings[$0].id }.forEach { midi.removeMapping($0) } }
                    Menu {
                        Button("Next preset") { midi.addMapping(.presetNext) }
                        Button("Previous preset") { midi.addMapping(.presetPrev) }
                        Button("Looper REC / Play / Dub") { midi.addMapping(.looper) }
                        Button("Looper stop") { midi.addMapping(.looperStop) }
                        Button("Tap tempo") { midi.addMapping(.tapTempo) }
                        Button("Mute") { midi.addMapping(.mute) }
                        Button("Tuner") { midi.addMapping(.tuner) }
                        Menu("Parameter / expression") { ForEach(MIDIParam.allCases) { p in Button(p.label) { midi.addMapping(.param(p)) } } }
                        Menu("Block on/off") { ForEach(BlockKind.allCases, id: \.self) { k in Button(k.rawValue) { midi.addMapping(.blockToggle(k.rawValue)) } } }
                    } label: { Label("Add mapping", systemImage: "plus") }
                }
            }
            .navigationTitle("MIDI")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showMIDI = false } } }
            #if os(iOS)
            .sheet(isPresented: $showBLE) { BluetoothMIDIView().ignoresSafeArea() }
            #endif
            .overlay {
                if midi.learnMappingID != nil {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Press a footswitch or move a pedal to learn it").font(.headline).multilineTextAlignment(.center)
                        Button("Cancel") { midi.cancelLearn() }.buttonStyle(.bordered)
                    }
                    .padding(28).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)).padding()
                }
            }
        }
    }

    /// Per-preset MIDI-out list (PC/CC sent to external gear when this preset loads).
    private var midiOutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.up.right.circle.fill").foregroundStyle(.orange)
                Text("MIDI Out (this preset)").font(.subheadline.bold())
                Spacer()
                Menu {
                    Button("Program Change") { var l = audio.currentMidiOut; l.append(MIDIOutMessage(kind: .programChange, channel: midi.outChannel)); audio.currentMidiOut = l }
                    Button("Control Change") { var l = audio.currentMidiOut; l.append(MIDIOutMessage(kind: .controlChange, channel: midi.outChannel, number: 1, value: 127)); audio.currentMidiOut = l }
                } label: { Image(systemName: "plus.circle.fill").font(.title3) }
            }
            if audio.currentMidiOut.isEmpty {
                Text("Messages sent to external pedals/amps when this preset loads.").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(audio.currentMidiOut.enumerated()), id: \.element.id) { i, m in
                HStack(spacing: 8) {
                    Picker("", selection: bindOut(i, \.kind)) { Text("PC").tag(MIDIOutMessage.Kind.programChange); Text("CC").tag(MIDIOutMessage.Kind.controlChange) }
                        .pickerStyle(.segmented).frame(width: 90)
                    Stepper("ch \(m.channel)", value: bindOut(i, \.channel), in: 1...16).fixedSize().font(.caption)
                    Stepper("# \(m.number)", value: bindOut(i, \.number), in: 0...127).fixedSize().font(.caption)
                    if m.kind == .controlChange { Stepper("= \(m.value)", value: bindOut(i, \.value), in: 0...127).fixedSize().font(.caption) }
                    Spacer(minLength: 0)
                    Button { midi.send(m) } label: { Image(systemName: "paperplane.fill") }.buttonStyle(.plain).foregroundStyle(.orange)
                    Button { var l = audio.currentMidiOut; l.remove(at: i); audio.currentMidiOut = l } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func bindOut<T>(_ i: Int, _ kp: WritableKeyPath<MIDIOutMessage, T>) -> Binding<T> {
        Binding(get: { audio.currentMidiOut[i][keyPath: kp] },
                set: { var l = audio.currentMidiOut; guard l.indices.contains(i) else { return }; l[i][keyPath: kp] = $0; audio.currentMidiOut = l })
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("TONE3000") {
                    if let token = UserDefaults.standard.string(forKey: "t3k_token") {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button { Pasteboard.copy(token) } label: { Label("Copy access token", systemImage: "doc.on.doc") }
                    } else {
                        Text("Not connected. Use Amp → Browse TONE3000 to log in.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Audio") {
                    #if os(macOS)
                    Picker("Input device", selection: Binding(get: { audio.inputDeviceName ?? "" }, set: { audio.inputDeviceName = $0.isEmpty ? nil : $0 })) {
                        Text("System default").tag("")
                        ForEach(audio.inputDevices) { d in Text("\(d.name) (\(d.inputs) in)").tag(d.name) }
                    }
                    Picker("Output device", selection: Binding(get: { audio.outputDeviceName ?? "" }, set: { audio.outputDeviceName = $0.isEmpty ? nil : $0 })) {
                        Text("System default").tag("")
                        ForEach(audio.outputDevices) { d in Text("\(d.name) (\(d.outputs) out)").tag(d.name) }
                    }
                    Text("Lowest latency + no drift: use the SAME interface for in and out (or an Aggregate Device from Audio MIDI Setup).")
                        .font(.caption).foregroundStyle(.secondary)
                    #endif
                    row("Sample rate", audio.sampleRate > 0 ? "\(Int(audio.sampleRate)) Hz" : "—")
                    row("Input / Output", audio.inputSampleRate > 0 ? "\(Int(audio.inputSampleRate)) / \(Int(audio.outputSampleRate)) Hz" : "—")
                    row("I/O buffer", fmt(audio.ioBufferMs))
                    row("Round-trip (buffer)", fmt(audio.roundTripMs))
                    Picker("Latency / stability", selection: $audio.preferredBufferFrames) {
                        #if os(macOS)
                        Text("Lowest · 64").tag(64.0)
                        #endif
                        Text("Low · 128").tag(128.0)
                        Text("Balanced · 256").tag(256.0)
                        Text("Safe · 512").tag(512.0)
                    }
                    row("OS-reported I/O", fmt(audio.reportedLatencyMs))
                }
                Section("Appearance") {
                    Picker("Theme", selection: $uiAppearance) {
                        Text("System").tag(0)
                        Text("Light").tag(1)
                        Text("Dark").tag(2)
                    }
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
                Section("Legal") {
                    NavigationLink { AcknowledgementsView() } label: {
                        Label("Acknowledgements", systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle("Settings")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
        }
        .sheetSize([.medium, .large])
    }

    private var presetManageSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(audio.presets.enumerated()), id: \.element.id) { i, p in
                        HStack(spacing: 10) {
                            Text(audio.tag(for: i))
                                .font(.system(size: 13, weight: .black, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(sceneColor(audio.scene(for: i)), in: RoundedRectangle(cornerRadius: 6))
                            Text(p.name).fontWeight(i == audio.currentPresetIndex ? .bold : .regular)
                            Spacer()
                            if i == audio.currentPresetIndex {
                                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.green)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { audio.loadPreset(at: i); showPresets = false }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { audio.deletePreset(at: i) } label: { Label("Delete", systemImage: "trash") }
                            Button { audio.duplicatePreset(at: i) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }.tint(.blue)
                            Button { renameText = p.name; renameIdx = i } label: { Label("Rename", systemImage: "pencil") }.tint(.orange)
                        }
                    }
                    .onMove { audio.movePreset(from: $0, to: $1) }
                } footer: {
                    Text("Tap to load · swipe a row for rename / duplicate / delete · tap Edit to drag-reorder. The tags (0A–0D, 1A…) and MIDI Program numbers follow this order.")
                }
            }
            .navigationTitle("Setlist")
            .inlineTitle()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                #endif
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showPresets = false } }
            }
            .alert("Rename preset", isPresented: Binding(get: { renameIdx != nil }, set: { if !$0 { renameIdx = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") { if let i = renameIdx { audio.renamePreset(at: i, to: renameText) }; renameIdx = nil }
                Button("Cancel", role: .cancel) { renameIdx = nil }
            }
        }
        .sheetSize([.large])
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
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showManage = false } } }
        }
        .sheetSize([.medium, .large])
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
