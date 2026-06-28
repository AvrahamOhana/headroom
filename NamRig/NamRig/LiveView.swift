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
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topRow
                Spacer(minLength: 8)
                presetName
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
            Circle().fill(audio.state == .running ? Color.green : Color.gray).frame(width: 11, height: 11)
                .shadow(color: audio.state == .running ? .green.opacity(0.7) : .clear, radius: 5)
            Button(action: onExit) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.white.opacity(0.45)) }
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
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.3).lineLimit(1)
            }
            Text(subtitle).font(.system(.title3, design: .monospaced)).foregroundStyle(.gray)
        }
        .padding(.horizontal, 14)
    }

    private var tunerButton: some View {
        Button(action: onTuner) {
            HStack(spacing: 8) {
                Image(systemName: "tuningfork")
                Text("Tuner").font(.system(.body, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.vertical, 7).padding(.horizontal, 22)
            .background(.white.opacity(0.08), in: Capsule())
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
                    .foregroundStyle(on ? .white : .white.opacity(0.28))
                    .background(on ? AnyShapeStyle(b.color.gradient) : AnyShapeStyle(Color.gray.opacity(0.16)),
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
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 26, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 60)
                .foregroundStyle(.white)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var subtitle: String {
        let total = max(audio.presets.count, 1)
        return "BANK \(audio.bankIndex + 1)  ·  SCENE \(audio.sceneInBank + 1)      PRESET \(audio.currentPresetIndex + 1)/\(total)"
    }
}
