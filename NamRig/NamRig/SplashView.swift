//
//  SplashView.swift
//  Headroom — in-app splash shown over the rig while the audio engine comes up, then fades. On iOS it
//  matches the static launch screen (same badge, same background) so the hand-off is seamless; on
//  macOS it is the only "loading page".
//

import SwiftUI

struct SplashView: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            RadialGradient(colors: [Color(red: 1, green: 0.55, blue: 0.15).opacity(0.18), .clear], center: .center, startRadius: 0, endRadius: 420)
                .ignoresSafeArea()
            VStack(spacing: 22) {
                Image("LaunchLogo")
                    .resizable().scaledToFit()
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 48))
                    .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
                VStack(spacing: 6) {
                    Text("Headroom").font(.system(size: 30, weight: .black, design: .rounded)).tracking(1)
                        .foregroundStyle(.white)
                    Text("AMP & FX").font(.system(size: 12, weight: .heavy, design: .rounded)).tracking(4)
                        .foregroundStyle(.white.opacity(0.55))
                }
                ProgressView().tint(.white.opacity(0.6)).padding(.top, 8)
            }
        }
    }
}
