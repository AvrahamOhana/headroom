//
//  Platform.swift
//  NamRig — the thin iOS / macOS seam. Everything platform-specific the UI touches goes through
//  here (haptics, images from disk, pasteboard, idle timer, sheet sizing, iOS-only modifiers) so
//  the rest of the app stays a single SwiftUI code base.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum Haptics {
    enum Style { case light, medium, rigid }
    static func impact(_ s: Style = .light) {
        #if os(iOS)
        let st: UIImpactFeedbackGenerator.FeedbackStyle = s == .light ? .light : s == .medium ? .medium : .rigid
        UIImpactFeedbackGenerator(style: st).impactOccurred()
        #endif
    }
    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}

enum Pasteboard {
    static func copy(_ s: String) {
        #if os(iOS)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
}

enum IdleTimer {
    static func keepAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}

/// Decoded artwork cache — tiles redraw often; decoding a JPEG per redraw is wasteful.
@MainActor private var artworkCache: [String: Image] = [:]
extension Image {
    /// Load an image file from disk (model artwork sidecars), cached by path. nil if unreadable.
    @MainActor init?(file path: String) {
        if let cached = artworkCache[path] { self = cached; return }
        #if os(iOS)
        guard let ui = UIImage(contentsOfFile: path) else { return nil }
        self.init(uiImage: ui)
        #else
        guard let ns = NSImage(contentsOfFile: path) else { return nil }
        self.init(nsImage: ns)
        #endif
        artworkCache[path] = self
    }
}

extension Color {
    static var platformBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

extension View {
    /// iOS: sheet detents. macOS: a sensible fixed sheet size instead (detents don't exist there).
    @ViewBuilder func sheetSize(_ detents: Set<PresentationDetent>, mac: CGSize = CGSize(width: 520, height: 620)) -> some View {
        #if os(iOS)
        presentationDetents(detents)
        #else
        // Never taller/wider than the visible screen (menu bar + Dock excluded), or the bottom is unreachable.
        let vis = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        frame(width: min(mac.width, vis.width - 80), height: min(mac.height, vis.height - 120))
        #endif
    }
    @ViewBuilder func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
    /// Full-screen on iOS; a large sheet on macOS.
    @ViewBuilder func fullScreen<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented) { content().frame(minWidth: 720, minHeight: 560) }
        #endif
    }
    @ViewBuilder func alwaysEditing() -> some View {
        #if os(iOS)
        environment(\.editMode, .constant(.active))
        #else
        self
        #endif
    }
    @ViewBuilder func hideStatusBar() -> some View {
        #if os(iOS)
        statusBarHidden(true)
        #else
        self
        #endif
    }
}

/// A menu whose custom label IS the button. iOS: a native Menu. macOS: a plain button + popover list
/// (macOS wraps Menu labels in its own pull-down chrome, which can't be turned off reliably).
struct PlainMenu<Content: View, Label: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label
    @State private var open = false
    var body: some View {
        #if os(macOS)
        Button { open.toggle() } label: { label() }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) { content() }
                        .buttonStyle(MenuItemStyle())
                        .padding(6)
                }
                .frame(minWidth: 220, maxHeight: 420)
                .simultaneousGesture(TapGesture().onEnded { open = false })
            }
        #else
        Menu { content() } label: { label() }.menuIndicator(.hidden)
        #endif
    }
}

/// Menu-row look for buttons inside a PlainMenu popover.
struct MenuItemStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(configuration.isPressed ? Color.accentColor.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}
