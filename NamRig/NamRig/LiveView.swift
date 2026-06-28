//
//  LiveView.swift
//  NamRig — full-screen "stage" display. Top: in/out meters + CPU. Center: huge preset name.
//  Bottom: live tuner, a mini signal-chain readout, and compact prev/next. Screen stays awake.
//

import SwiftUI
import UIKit

struct LiveView: View {
    let audio: AudioEngine
    var onExit: () -> Void
    var onTuner: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                topRow
                Spacer(minLength: 8)
                presetName
                neighbors
                Spacer(minLength: 8)
                tunerButton
                chainViz
                prevNext
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .statusBarHidden(true)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: top — shared signal strip + run light + close
    private var topRow: some View {
        HStack(spacing: 14) {
            SignalStrip(audio: audio)
            Spacer()
            Button { audio.toggleMute() } label: {
                Image(systemName: audio.muted ? "speaker.slash.circle.fill" : "speaker.wave.2.circle")
                    .font(.title2).foregroundStyle(audio.muted ? .red : .secondary)
            }.buttonStyle(.plain)
            Circle().fill(audio.state == .running ? Color.green : Color.gray).frame(width: 11, height: 11)
                .shadow(color: audio.state == .running ? .green.opacity(0.7) : .clear, radius: 5)
            Button(action: onExit) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
    }

    // MARK: center — huge preset name
    private var presetName: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Text(audio.presetTag)
                    .font(.system(size: 40, weight: .black, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(sceneColor(audio.sceneInBank), in: RoundedRectangle(cornerRadius: 12))
                    .fixedSize()
                Text(audio.currentPresetName)
                    .font(.system(size: 104, weight: .black, design: .rounded))
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.3).lineLimit(1)
            }
            Text(subtitle).font(.system(.title3, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
    }

    // MARK: neighbor preview — what's prev / next, scene-tinted (no-look confidence)
    private var neighbors: some View {
        HStack {
            neighborLabel(audio.currentPresetIndex - 1, trailing: false)
            Spacer()
            neighborLabel(audio.currentPresetIndex + 1, trailing: true)
        }
        .padding(.horizontal, 6)
    }
    @ViewBuilder private func neighborLabel(_ idx: Int, trailing: Bool) -> some View {
        let n = audio.presets.count
        if n > 1 {
            let wi = ((idx % n) + n) % n
            HStack(spacing: 7) {
                if !trailing { Image(systemName: "chevron.left").font(.caption2.bold()) }
                Text(audio.tag(for: wi)).font(.system(size: 14, weight: .black, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(sceneColor(audio.scene(for: wi)).opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
                Text(audio.presets[wi].name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                if trailing { Image(systemName: "chevron.right").font(.caption2.bold()) }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var tunerButton: some View {
        Button(action: onTuner) {
            HStack(spacing: 8) {
                Image(systemName: "tuningfork")
                Text("Tuner").font(.system(.body, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 7).padding(.horizontal, 22)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain).padding(.bottom, 12)
    }

    // MARK: bottom — mini signal-chain readout
    private var chainViz: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(audio.blockOrder.compactMap { ChainBlock($0) }) { b in
                    let on = audio.isBlockEnabled(b.kind)
                    VStack(spacing: 3) {
                        Image(systemName: b.icon).font(.system(size: 13, weight: .semibold))
                        Text(b.short).font(.system(size: 7, weight: .heavy))
                    }
                    .frame(width: 40, height: 42)
                    .foregroundStyle(on ? .white : .secondary)
                    .background(on ? AnyShapeStyle(b.color.gradient) : AnyShapeStyle(.quaternary),
                                in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(.bottom, 12)
    }

    // MARK: compact prev/next
    private var prevNext: some View {
        HStack(spacing: 12) {
            navButton("chevron.left", action: audio.prevPreset)
            navButton("chevron.right", action: audio.nextPreset)
        }
    }
    private func navButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(); action() } label: {
            Image(systemName: icon).font(.system(size: 26, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 60)
                .foregroundStyle(.primary)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var subtitle: String {
        let total = max(audio.presets.count, 1)
        return "PRESET \(audio.currentPresetIndex + 1) / \(total)"
    }
}
