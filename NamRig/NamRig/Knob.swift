//
//  Knob.swift
//  NamRig — rotary knob control (the modeler look). Drag up/down (or around) to turn, double-tap
//  to reset to the default, light haptic at the detent. Renders a 270° arc with a value readout.
//

import SwiftUI

struct Knob: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit: String = ""
    var decimals: Int = 0
    var color: Color = .accentColor
    var defaultValue: Double? = nil
    var bipolar: Bool = false          // arc fills from the center (EQ ±dB) instead of from the left
    var size: CGFloat = 64

    @State private var dragStartValue: Double? = nil
    @State private var lastDetentHit = false

    private var norm: Double { max(0, min(1, (value - range.lowerBound) / (range.upperBound - range.lowerBound))) }
    private var centerNorm: Double { bipolar ? (0 - range.lowerBound) / (range.upperBound - range.lowerBound) : 0 }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().trim(from: 0, to: 0.75)
                    .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: CGFloat(min(norm, centerNorm) * 0.75), to: CGFloat(max(norm, centerNorm) * 0.75))
                    .stroke(color.gradient, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().fill(.background.shadow(.inner(color: .black.opacity(0.35), radius: 3)))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                    .padding(size * 0.15)
                Capsule().fill(color)
                    .frame(width: size * 0.06, height: size * 0.2)
                    .offset(y: -size * 0.24)
                    .rotationEffect(.degrees(-135 + norm * 270))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(drag)
            .onTapGesture(count: 2) { if let d = defaultValue { set(d); tick() } }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(readout)
            .accessibilityAdjustableAction { dir in
                let step = (range.upperBound - range.lowerBound) / 40
                set(value + (dir == .increment ? step : -step))
            }
            Text(readout).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
            Text(label.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: max(size, 72))
    }

    private var readout: String {
        let v = decimals == 0 ? String(Int(value.rounded())) : String(format: "%.\(decimals)f", value)
        return unit.isEmpty ? v : "\(v)\(unit.hasPrefix("%") || unit == "x" || unit == "°" ? "" : " ")\(unit)"
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                if dragStartValue == nil { dragStartValue = value }
                guard let start = dragStartValue else { return }
                let span = range.upperBound - range.lowerBound
                let delta = (-g.translation.height + g.translation.width * 0.5) / 180 * span
                let v = max(range.lowerBound, min(range.upperBound, start + delta))
                if let d = defaultValue, abs(v - d) < span * 0.015 {
                    if !lastDetentHit { tick(); lastDetentHit = true }
                    set(d)
                } else { lastDetentHit = false; set(v) }
            }
            .onEnded { _ in dragStartValue = nil; lastDetentHit = false }
    }

    private func set(_ v: Double) { value = max(range.lowerBound, min(range.upperBound, v)) }
    private func tick() { Haptics.impact(.light) }
}

/// Adaptive row of knobs — wraps at phone width, single row on iPad/landscape.
struct KnobGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], alignment: .center, spacing: 12) { content() }
            .frame(maxWidth: .infinity)
    }
}

/// Small stomp-style footswitch toggle (used for on/off inside editors and the Live view).
struct FootswitchToggle: View {
    @Binding var isOn: Bool
    var color: Color = .green
    var body: some View {
        Button { isOn.toggle(); Haptics.impact(.medium) } label: {
            ZStack {
                Circle().fill(Color.primary.opacity(0.08)).frame(width: 34, height: 34)
                Circle().fill(isOn ? color : Color.secondary.opacity(0.35)).frame(width: 12, height: 12)
                    .shadow(color: isOn ? color.opacity(0.8) : .clear, radius: 6)
            }
        }.buttonStyle(.plain)
    }
}
