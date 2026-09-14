//
//  ChainStrip.swift
//  NamRig — the signal-chain strip: one draggable row per path (A / B), LOOP + OUT tiles.
//
//  Drag & drop is gesture-driven (not the system drag session): a short hold lifts the tile, it
//  follows the finger, the other tiles slide open a gap live (placeholder), and moving the finger
//  onto the other row re-targets it. Tile frames are collected through a PreferenceKey in the strip's
//  own coordinate space, so scrolled rows still hit-test correctly. The engine is only touched once,
//  on release (`moveBlock`).
//

import SwiftUI

private struct TileKey: Hashable { let path: RigPathID; let kind: BlockKind }
private struct TileFramesKey: PreferenceKey {
    static let defaultValue: [TileKey: CGRect] = [:]
    static func reduce(value: inout [TileKey: CGRect], nextValue: () -> [TileKey: CGRect]) { value.merge(nextValue()) { $1 } }
}
private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [RigPathID: CGRect] = [:]
    static func reduce(value: inout [RigPathID: CGRect], nextValue: () -> [RigPathID: CGRect]) { value.merge(nextValue()) { $1 } }
}

struct ChainStripView: View {
    let audio: AudioEngine
    @Binding var selected: ChainBlock?
    @Binding var outputSelected: Bool
    @Binding var looperSelected: Bool
    @Binding var showReorder: Bool

    private struct Drag {
        let kind: BlockKind
        let from: RigPathID
        var location: CGPoint          // finger, in strip space
        var grabOffset: CGSize         // finger − tile center at lift
        var target: (path: RigPathID, index: Int)?
        var lifted = false
        /// Center x of slot 0 per row, snapshotted at lift. Slots are a uniform grid (tile + connector),
        /// so the drop index is `round((x − origin) / pitch)` — deterministic, no re-measuring mid-drag.
        var origins: [RigPathID: CGFloat] = [:]
    }
    /// Measured geometry lives in a reference box, NOT @State: writing it from a preference change
    /// must not invalidate the view (that was a layout→measure→layout loop that froze the UI).
    private final class FrameStore { var tiles: [TileKey: CGRect] = [:]; var rows: [RigPathID: CGRect] = [:] }
    @State private var drag: Drag? = nil
    @State private var frames = FrameStore()
    private let tileW: CGFloat = 58, tileH: CGFloat = 74
    private let spacing: CGFloat = 4, connectorW: CGFloat = 6
    private var pitch: CGFloat { tileW + connectorW + 2 * spacing }
    private let space = "chainStrip"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("SIGNAL CHAIN").font(.caption.bold()).foregroundStyle(.secondary)
                if audio.dualOn {
                    Text("drag tiles between A and B").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button { audio.dualOn.toggle(); Haptics.impact(.medium) } label: {
                    Label(audio.dualOn ? "A ∥ B" : "Dual", systemImage: audio.dualOn ? "rectangle.split.1x2.fill" : "rectangle.split.1x2")
                        .font(.caption.bold())
                }.buttonStyle(.plain).foregroundStyle(audio.dualOn ? .cyan : .secondary)
                Button { showReorder = true } label: {
                    Label("List", systemImage: "list.bullet").font(.caption.bold())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            pathRow(.a)
            if audio.dualOn { pathRow(.b) }
            HStack(spacing: 4) {
                endLabel(audio.dualOn ? "A+B" : "")
                connector
                looperTile
                connector
                outputTile
                Spacer()
            }
            .padding(.vertical, 2)
        }
        .coordinateSpace(name: space)
        .onPreferenceChange(TileFramesKey.self) { [frames] v in frames.tiles = v }
        .onPreferenceChange(RowFramesKey.self) { [frames] v in frames.rows = v }
        .overlay(alignment: .topLeading) { liftedTile }
    }

    // MARK: rows

    /// The order a row DISPLAYS while dragging: the dragged tile is pulled out and a gap (nil) is
    /// opened at the target index.
    private func displayOrder(_ id: RigPathID) -> [BlockKind?] {
        var kinds: [BlockKind?] = audio.order(of: id)
        guard let d = drag, d.lifted else { return kinds }
        kinds.removeAll { $0 == d.kind }
        if let t = d.target, t.path == id { kinds.insert(nil, at: min(t.index, kinds.count)) }
        return kinds
    }

    private func pathRow(_ id: RigPathID) -> some View {
        let order = displayOrder(id)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                endLabel(audio.dualOn ? id.label : "IN")
                ForEach(Array(order.enumerated()), id: \.offset) { i, kind in
                    connector
                    if let kind, let cb = ChainBlock(kind) {
                        tile(cb, in: id)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: TileFramesKey.self, value: [TileKey(path: id, kind: kind): g.frame(in: .named(space))])
                            })
                    } else {
                        gap
                    }
                }
                connector
                addTile(id)
            }
            .padding(.vertical, 2)
            .animation(.snappy(duration: 0.22), value: order.map { $0?.rawValue ?? "·" })
        }
        .background(GeometryReader { g in Color.clear.preference(key: RowFramesKey.self, value: [id: g.frame(in: .named(space))]) })
        .overlay(alignment: .leading) {
            if audio.dualOn {
                RoundedRectangle(cornerRadius: 2).fill(audio.focus == id ? Color.cyan : Color.clear).frame(width: 3, height: 60)
            }
        }
        .overlay {
            if let d = drag, d.lifted, d.target?.path == id {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.cyan.opacity(0.5), lineWidth: 1.5).padding(-2)
            }
        }
    }

    private var gap: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.cyan.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4]))
            .background(Color.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .frame(width: tileW, height: tileH)
            .transition(.scale.combined(with: .opacity))
    }

    // MARK: tiles

    private func tileFace(_ block: ChainBlock, on: Bool, selected sel: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: block.icon).font(.system(size: 20, weight: .semibold))
            Text(block.short).font(.system(size: 10, weight: .heavy))
        }
        .frame(width: tileW, height: tileH)
        .foregroundStyle(on ? .white : .white.opacity(0.3))
        .background(on ? block.color.gradient : Color.gray.opacity(0.22).gradient, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(sel ? .white : .clear, lineWidth: 2))
    }

    private func tile(_ block: ChainBlock, in id: RigPathID) -> some View {
        let on = audio.isBlockEnabled(block.kind, in: id), sel = selected == block && audio.focus == id
        return tileFace(block, on: on, selected: sel)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                audio.setFocus(id)
                selected = (sel ? nil : block); outputSelected = false; looperSelected = false
            }
            .gesture(dragGesture(block.kind, in: id))
            .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    /// Short hold (so horizontal scrolling still works), then the tile follows the finger.
    private func dragGesture(_ kind: BlockKind, in id: RigPathID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.12, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(space)))
            .onChanged { value in
                guard case .second(true, let g?) = value else { return }
                if drag == nil {
                    let center = frames.tiles[TileKey(path: id, kind: kind)].map { CGPoint(x: $0.midX, y: $0.midY) } ?? g.startLocation
                    var d = Drag(kind: kind, from: id, location: g.location,
                                 grabOffset: CGSize(width: g.startLocation.x - center.x, height: g.startLocation.y - center.y))
                    // Slot-0 origin per row from the tiles as laid out right now (nothing is animating yet).
                    for row in (audio.dualOn ? RigPathID.allCases : [.a]) {
                        let order = audio.order(of: row)
                        if let (i, f) = order.enumerated().compactMap({ i, k in frames.tiles[TileKey(path: row, kind: k)].map { (i, $0) } }).first {
                            d.origins[row] = f.midX - CGFloat(i) * pitch
                        } else if let rf = frames.rows[row] {
                            d.origins[row] = rf.minX + 26 + spacing + connectorW + spacing + tileW / 2   // empty row: after the end label
                        }
                    }
                    drag = d
                    Haptics.impact(.medium)
                }
                drag?.location = g.location
                if drag?.lifted == false { withAnimation(.snappy(duration: 0.15)) { drag?.lifted = true } }
                retarget(g.location)
            }
            .onEnded { _ in commitDrag() }
    }

    private func retarget(_ p: CGPoint) {
        guard var d = drag else { return }
        let rows = audio.dualOn ? RigPathID.allCases : [.a]
        // Row: the one whose vertical band is nearest the finger.
        let row = rows.min { a, b in
            let fa = frames.rows[a] ?? .zero, fb = frames.rows[b] ?? .zero
            return abs(p.y - fa.midY) < abs(p.y - fb.midY)
        } ?? d.from
        if row != d.from && audio.order(of: row).contains(d.kind) {            // that path already has one
            if d.target != nil { d.target = nil; drag = d }
            return
        }
        let others = audio.order(of: row).filter { $0 != d.kind }
        let origin = d.origins[row] ?? p.x
        let idx = max(0, min(others.count, Int(((p.x - origin) / pitch).rounded())))
        let new = (path: row, index: idx)
        if d.target?.path != new.path || d.target?.index != new.index {
            if d.target != nil { Haptics.impact(.light) }
            withAnimation(.snappy(duration: 0.2)) { drag?.target = new }
        }
    }

    private func commitDrag() {
        guard let d = drag else { return }
        withAnimation(.snappy(duration: 0.22)) { drag = nil }
        guard let t = d.target else { return }
        let others = audio.order(of: t.path).filter { $0 != d.kind }
        let before = t.index < others.count ? others[t.index] : nil
        if t.path == d.from {
            var proposed = others; proposed.insert(d.kind, at: min(t.index, others.count))
            if proposed == audio.order(of: d.from) { return }      // dropped where it was
        }
        audio.moveBlock(d.kind, from: d.from, to: t.path, before: before)
        if selected?.kind == d.kind { audio.setFocus(t.path) }
        Haptics.impact(.light)
    }

    /// The tile that follows the finger, drawn above everything in the strip's coordinate space.
    @ViewBuilder private var liftedTile: some View {
        if let d = drag, d.lifted, let cb = ChainBlock(d.kind) {
            tileFace(cb, on: audio.isBlockEnabled(d.kind, in: d.from), selected: false)
                .scaleEffect(1.08)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                .opacity(d.target == nil ? 0.5 : 1)
                .position(x: d.location.x - d.grabOffset.width, y: d.location.y - d.grabOffset.height)
                .allowsHitTesting(false)
        }
    }

    private func addTile(_ id: RigPathID) -> some View {
        let avail = audio.availableToAdd(in: id)
        return Menu {
            ForEach(avail, id: \.self) { kind in
                if let cb = ChainBlock(kind) {
                    Button { audio.addBlock(kind, in: id); audio.setFocus(id); selected = cb; outputSelected = false; looperSelected = false } label: { Label(cb.full, systemImage: cb.icon) }
                }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 20, weight: .semibold))
                Text("ADD").font(.system(size: 10, weight: .heavy))
            }
            .frame(width: tileW, height: tileH)
            .foregroundStyle(.secondary)
            .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [4])))
        }
        .disabled(avail.isEmpty)
    }

    private var looperTile: some View {
        let active = audio.looperStateLabel != "Idle"
        return Button { looperSelected.toggle(); outputSelected = false; selected = nil } label: {
            VStack(spacing: 6) {
                Image(systemName: "repeat.circle.fill").font(.system(size: 20, weight: .semibold))
                Text("LOOP").font(.system(size: 10, weight: .heavy))
            }
            .frame(width: tileW, height: tileH)
            .foregroundStyle(.white)
            .background(active ? Color.green.gradient : Color.green.opacity(0.45).gradient, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(looperSelected ? .white : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private var outputTile: some View {
        Button { outputSelected.toggle(); selected = nil; looperSelected = false } label: {
            VStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 20, weight: .semibold))
                Text("OUT").font(.system(size: 10, weight: .heavy))
            }
            .frame(width: tileW, height: tileH)
            .foregroundStyle(.white)
            .background(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(outputSelected ? .white : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func endLabel(_ t: String) -> some View {
        Text(t).font(.caption2.bold()).foregroundStyle(.secondary).frame(width: 26, height: tileH)
    }
    private var connector: some View { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 6, height: 2) }
}
