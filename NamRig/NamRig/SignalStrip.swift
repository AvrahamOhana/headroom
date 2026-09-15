//
//  SignalStrip.swift
//  NamRig — shared compact IN/OUT LED meters + CPU readout, used in both the main screen and Live mode.
//

import SwiftUI

struct SignalStrip: View {
    let audio: AudioEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { _ in
            let cpu = audio.cpuPercent
            HStack(spacing: 12) {
                meter("IN", audio.inPeakDb)
                meter("OUT", audio.outPeakDb)
                HStack(spacing: 4) {
                    LED(on: true, color: cpu > 80 ? .red : (cpu > 50 ? .orange : .green), size: 7)
                    Text("\(cpu)%").font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(cpu > 80 ? .red : .gray)
                }
            }
        }
    }

    private func meter(_ label: String, _ db: Float) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.gray).fixedSize()
            LEDMeter(db: db, segments: 12, height: 6).frame(width: 60)
        }
    }
}

/// Per-scene accent colour (A/B/C/D) for the preset/bank tag — stable, stage-readable.
func sceneColor(_ scene: Int) -> Color {
    [.blue, .green, .orange, .pink][((scene % 4) + 4) % 4]
}
