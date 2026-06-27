//
//  SignalStrip.swift
//  NamRig — shared compact IN/OUT meters + CPU readout, used in both the main screen and Live mode.
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
                    Circle().fill(cpu > 80 ? Color.red : (cpu > 50 ? Color.orange : Color.green)).frame(width: 7, height: 7)
                    Text("\(cpu)%").font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(cpu > 80 ? .red : .gray)
                }
            }
        }
    }

    private func meter(_ label: String, _ db: Float) -> some View {
        let norm = max(0, min(1, (Double(db) + 60) / 60))
        return HStack(spacing: 5) {
            Text(label).font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.gray).fixedSize()
            ZStack(alignment: .leading) {
                Capsule().fill(.gray.opacity(0.22))
                Rectangle().fill(db > -1 ? Color.red : Color.green).scaleEffect(x: CGFloat(norm), anchor: .leading)
            }
            .frame(width: 58, height: 6).clipShape(Capsule())
        }
    }
}

/// Per-scene accent colour (A/B/C/D) for the preset/bank tag — stable, stage-readable.
func sceneColor(_ scene: Int) -> Color {
    [.blue, .green, .orange, .pink][((scene % 4) + 4) % 4]
}
