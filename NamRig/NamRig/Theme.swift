//
//  Theme.swift
//  NamRig — the "gear" look, all vector (no image assets, cheap on an iPhone 11):
//  stage background, device chassis panels, LEDs, LED ladder meters, LED-style readout displays.
//

import SwiftUI

enum Stage {
    static let bgTop = Color(red: 0.11, green: 0.115, blue: 0.13)
    static let bgBottom = Color(red: 0.05, green: 0.05, blue: 0.06)
    static let panel = Color(red: 0.16, green: 0.165, blue: 0.185)
    static let panelLight = Color(red: 0.97, green: 0.97, blue: 0.98)
    static let panelLightBottom = Color(red: 0.86, green: 0.86, blue: 0.88)
    static let floorLight = Color(red: 0.80, green: 0.80, blue: 0.82)
    static let display = Color(red: 0.04, green: 0.05, blue: 0.05)
    static let displayInk = Color(red: 0.55, green: 1.0, blue: 0.75)
}

/// Dark stage floor with a soft top-light vignette (light mode: a plain warm gray).
struct StageBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            if scheme == .dark {
                LinearGradient(colors: [Stage.bgTop, Stage.bgBottom], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [.white.opacity(0.06), .clear], center: .top, startRadius: 0, endRadius: 520)
            } else {
                LinearGradient(colors: [Stage.floorLight, Color(red: 0.72, green: 0.72, blue: 0.75)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [.white.opacity(0.45), .clear], center: .top, startRadius: 0, endRadius: 520)
            }
        }
        .ignoresSafeArea()
    }
}

/// A device chassis: metallic panel with a colored top rail, top-edge highlight, inner shadow.
struct Chassis: ViewModifier {
    var accent: Color
    var rail: CGFloat = 4
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(scheme == .dark ? AnyShapeStyle(Stage.panel.gradient)
                                              : AnyShapeStyle(LinearGradient(colors: [Stage.panelLight, Stage.panelLightBottom], startPoint: .top, endPoint: .bottom)))
                        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.28), radius: 10, y: 6)
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(scheme == .dark
                                      ? AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                      : AnyShapeStyle(Color.black.opacity(0.18)), lineWidth: 1)
                    UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 14)
                        .fill(accent.gradient).frame(height: rail)
                }
            }
    }
}
extension View {
    func chassis(_ accent: Color, rail: CGFloat = 4) -> some View { modifier(Chassis(accent: accent, rail: rail)) }
}

/// A status LED — glows when on, dark bead when off.
struct LED: View {
    var on: Bool
    var color: Color = .green
    var size: CGFloat = 8
    var body: some View {
        Circle()
            .fill(on ? color : Color.black.opacity(0.55))
            .overlay(Circle().strokeBorder(.white.opacity(on ? 0.5 : 0.15), lineWidth: 0.6))
            .overlay(alignment: .top) { Circle().fill(.white.opacity(on ? 0.55 : 0.12)).frame(width: size * 0.35, height: size * 0.35).offset(y: size * 0.12) }
            .shadow(color: on ? color.opacity(0.9) : .clear, radius: size * 0.7)
            .frame(width: size, height: size)
    }
}

/// Segmented LED ladder meter (green → amber → red), horizontal.
struct LEDMeter: View {
    var db: Float                 // dBFS
    var segments = 14
    var height: CGFloat = 8
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let lit = Int((max(0, min(1, (Double(db) + 60) / 60)) * Double(segments)).rounded())
        HStack(spacing: 1.5) {
            ForEach(0..<segments, id: \.self) { i in
                let frac = Double(i) / Double(segments)
                let c: Color = frac > 0.9 ? .red : (frac > 0.72 ? .yellow : .green)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i < lit ? c : c.opacity(scheme == .dark ? 0.14 : 0.3))
                    .shadow(color: i < lit ? c.opacity(0.6) : .clear, radius: 2)
            }
        }
        .padding(2)
        .background(Color.black.opacity(scheme == .dark ? 0.35 : 0.55), in: RoundedRectangle(cornerRadius: 3))
        .frame(height: height + 4)
    }
}

/// Inset LED-style readout (preset display, values).
struct DisplayPanel<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 10).fill(Stage.display)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.8), lineWidth: 1))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08), lineWidth: 1).padding(1))
                    .overlay(LinearGradient(colors: [.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center).clipShape(RoundedRectangle(cornerRadius: 10)))
            }
    }
}

/// Engraved-looking label used on device panels.
struct Nameplate: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(1.2)
            .foregroundStyle(.primary.opacity(0.75))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.black.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
    }
}
