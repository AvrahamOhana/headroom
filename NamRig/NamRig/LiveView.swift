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

    // MARK: top — in/out meters + CPU + close
    private var topRow: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { _ in
            let cpu = audio.cpuPercent
            HStack(spacing: 16) {
                meter("IN", audio.inPeakDb)
                meter("OUT", audio.outPeakDb)
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(cpu > 80 ? Color.red : (cpu > 50 ? Color.orange : Color.green)).frame(width: 7, height: 7)
                    Text("\(cpu)%").font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(cpu > 80 ? .red : .gray)
                }
                Circle().fill(audio.state == .running ? Color.green : Color.gray).frame(width: 11, height: 11)
                Button(action: onExit) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.white.opacity(0.45)) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func meter(_ label: String, _ db: Float) -> some View {
        let norm = max(0, min(1, (Double(db) + 60) / 60))
        return HStack(spacing: 6) {
            Text(label).font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(.gray)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Rectangle().fill(db > -1 ? Color.red : Color.green).scaleEffect(x: CGFloat(norm), anchor: .leading)
            }
            .frame(width: 72, height: 6).clipShape(Capsule())
        }
    }

    // MARK: center — huge preset name
    private var presetName: some View {
        VStack(spacing: 14) {
            Text(audio.currentPresetName)
                .font(.system(size: 150, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.25).lineLimit(2).multilineTextAlignment(.center)
            Text(subtitle).font(.system(.title3, design: .monospaced)).foregroundStyle(.gray)
        }
        .padding(.horizontal, 14)
    }

    private var tunerButton: some View {
        Button(action: onTuner) {
            HStack(spacing: 8) {
                Image(systemName: "tuningfork")
                Text(audio.tunerActive ? "\(audio.tunerNote) \(audio.tunerCents > 0 ? "+" : "")\(audio.tunerCents)¢" : "Tuner")
                    .font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
            }
            .foregroundStyle(audio.tunerActive && abs(audio.tunerCents) <= 4 ? .green : .white.opacity(0.8))
            .padding(.vertical, 7).padding(.horizontal, 18)
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
