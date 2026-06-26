//
//  ContentView.swift
//  NamRig — amp + noise gate
//

import SwiftUI

struct ContentView: View {
    @State private var audio = AudioEngine()
    private var isRunning: Bool { audio.state == .running }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                startButton

                // Model + amp + meters
                card {
                    Picker("Amp model", selection: $audio.selectedModel) {
                        ForEach(AudioEngine.AmpModel.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isRunning)

                    Toggle(isOn: $audio.ampEnabled) {
                        Label(audio.ampEnabled ? "Amp engaged" : "Dry (bypass)", systemImage: "amplifier")
                            .font(.headline)
                    }
                    .toggleStyle(.switch).tint(.orange)
                    .disabled(!audio.modelLoaded)

                    Text(audio.modelStatus).font(.caption).foregroundStyle(.secondary)

                    TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                        VStack(spacing: 8) {
                            meter("In (to amp)", audio.inPeakDb)
                            meter("Amp out", audio.outPeakDb)
                        }
                    }
                }

                // Noise gate (first effect)
                card {
                    Toggle(isOn: $audio.gateEnabled) {
                        Label("Noise gate", systemImage: "waveform.path.ecg").font(.headline)
                    }
                    .tint(.mint)
                    sliderRow("Threshold", value: $audio.gateThresholdDb, range: -70 ... -10)
                        .disabled(!audio.gateEnabled)
                }

                // Amp controls
                card {
                    sliderRow("Drive", value: $audio.inputDriveDb, range: 0...24)
                    sliderRow("Output", value: $audio.outputLevelDb, range: -40...12)
                }

                // Telemetry
                card {
                    row("Status", audio.state.rawValue)
                    row("Sample rate", audio.sampleRate > 0 ? "\(Int(audio.sampleRate)) Hz" : "—")
                    row("I/O buffer", fmt(audio.ioBufferMs))
                    row("Est. round-trip", fmt(audio.roundTripMs), emphasized: true)
                }

                if let err = audio.lastError {
                    Text(err).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .onAppear { audio.loadModel() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 4) {
            Text("NamRig").font(.largeTitle.bold())
            Text("amp + noise gate").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 16)
    }

    private var startButton: some View {
        Button(action: audio.toggle) {
            Label(isRunning ? "Stop" : "Start", systemImage: isRunning ? "stop.circle.fill" : "play.circle.fill")
                .font(.system(size: 22, weight: .bold))
                .frame(maxWidth: .infinity).padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(isRunning ? .red : .green)
    }

    // MARK: - Pieces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) { content() }
            .padding()
            .frame(maxWidth: .infinity)
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
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.25))
                    Capsule().fill(db > -1 ? .red : .green).frame(width: geo.size.width * norm)
                }
            }
            .frame(height: 8)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text("\(Int(value.wrappedValue)) dB").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func fmt(_ ms: Double) -> String { ms > 0 ? String(format: "%.1f ms", ms) : "—" }

    private func row(_ label: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(emphasized ? .bold : .semibold)
        }
        .font(emphasized ? .body : .subheadline)
    }
}

#Preview { ContentView() }
