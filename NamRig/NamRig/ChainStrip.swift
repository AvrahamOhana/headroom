//
//  ChainStrip.swift
//  NamRig — the signal-chain strip: one draggable row per path (A / B), LOOP + OUT tiles.
//  Tiles are block INSTANCES (a kind can appear several times).
//
//  Drag & drop is gesture-driven (not the system drag session): a short hold lifts the tile, it
//  follows the finger, the other tiles slide open a gap live (placeholder), and moving the finger
//  onto the other row re-targets it. Measured geometry lives in a reference box (never @State) and
//  the drop slot comes from a fixed grid snapshotted at lift, so nothing re-measures mid-drag. The
//  engine is touched once, on release (`moveInstance`).
//

import SwiftUI

private struct TileFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}
private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [RigPathID: CGRect] = [:]
    static func reduce(value: inout [RigPathID: CGRect], nextValue: () -> [RigPathID: CGRect]) { value.merge(nextValue()) { $1 } }
}

struct ChainStripView: View {
    let audio: AudioEngine
    @Binding var selectedID: UUID?
    @Binding var outputSelected: Bool
    @Binding var looperSelected: Bool
    @Binding var showReorder: Bool

    private struct Drag {
        let inst: BlockInstance
        let from: RigPathID
        var location: CGPoint
        var grabOffset: CGSize
        var target: (path: RigPathID, index: Int)?
        var lifted = false
        var origins: [RigPathID: CGFloat] = [:]   // center x of slot 0 per row, snapshotted at lift
    }
    private final class FrameStore { var tiles: [UUID: CGRect] = [:]; var rows: [RigPathID: CGRect] = [:] }
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
                Text(audio.dualOn ? "hold a tile to drag · rows A and B" : "hold a tile to drag").font(.caption2).foregroundStyle(.tertiary)
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

    /// The order a row DISPLAYS while dragging: the dragged tile is pulled out and a gap (nil) opened at the target.
    private func displayOrder(_ id: RigPathID) -> [BlockInstance?] {
        var items: [BlockInstance?] = audio.instances(of: id)
        guard let d = drag, d.lifted else { return items }
        items.removeAll { $0?.id == d.inst.id }
        if let t = d.target, t.path == id { items.insert(nil, at: min(t.index, items.count)) }
        return items
    }

    private func pathRow(_ id: RigPathID) -> some View {
        let order = displayOrder(id)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                endLabel(audio.dualOn ? id.label : "IN")
                ForEach(Array(order.enumerated()), id: \.offset) { _, item in
                    connector
                    if let inst = item, let cb = ChainBlock(inst.kind) {
                        tile(inst, cb, in: id)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: TileFramesKey.self, value: [inst.id: g.frame(in: .named(space))])
                            })
                    } else {
                        gap
                    }
                }
                connector
                addTile(id)
            }
            .padding(.vertical, 2)
            .animation(.snappy(duration: 0.22), value: order.map { $0?.id.uuidString ?? "·" })
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

    private func tileFace(_ block: ChainBlock, suffix: String?, on: Bool, selected sel: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: block.icon).font(.system(size: 20, weight: .semibold))
            Text(suffix.map { "\(block.short) \($0)" } ?? block.short).font(.system(size: 10, weight: .heavy))
        }
        .frame(width: tileW, height: tileH)
        .foregroundStyle(on ? .white : .white.opacity(0.3))
        .background(on ? block.color.gradient : Color.gray.opacity(0.22).gradient, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(sel ? .white : .clear, lineWidth: 2))
    }

    private func tile(_ inst: BlockInstance, _ block: ChainBlock, in id: RigPathID) -> some View {
        let on = audio.isEnabled(inst.id, in: id), sel = selectedID == inst.id
        return tileFace(block, suffix: audio.label(for: inst.id, in: id), on: on, selected: sel)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                audio.focusInstance(inst.id, in: id)
                selectedID = sel ? nil : inst.id; outputSelected = false; looperSelected = false
            }
            .gesture(dragGesture(inst, in: id))
            .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    /// Short hold (so horizontal scrolling still works), then the tile follows the finger.
    private func dragGesture(_ inst: BlockInstance, in id: RigPathID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.12, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(space)))
            .onChanged { value in
                guard case .second(true, let g?) = value else { return }
                if drag == nil {
                    let center = frames.tiles[inst.id].map { CGPoint(x: $0.midX, y: $0.midY) } ?? g.startLocation
                    var d = Drag(inst: inst, from: id, location: g.location,
                                 grabOffset: CGSize(width: g.startLocation.x - center.x, height: g.startLocation.y - center.y))
                    for row in (audio.dualOn ? RigPathID.allCases : [.a]) {
                        let list = audio.instances(of: row)
                        if let (i, f) = list.enumerated().compactMap({ i, b in frames.tiles[b.id].map { (i, $0) } }).first {
                            d.origins[row] = f.midX - CGFloat(i) * pitch
                        } else if let rf = frames.rows[row] {
                            d.origins[row] = rf.minX + 26 + spacing + connectorW + spacing + tileW / 2
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
        let row = rows.min { a, b in
            let fa = frames.rows[a] ?? .zero, fb = frames.rows[b] ?? .zero
            return abs(p.y - fa.midY) < abs(p.y - fb.midY)
        } ?? d.from
        if row != d.from && !audio.availableToAdd(in: row).contains(d.inst.kind) {   // that path is full of this kind
            if d.target != nil { d.target = nil; drag = d }
            return
        }
        let others = audio.instances(of: row).filter { $0.id != d.inst.id }
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
        let others = audio.instances(of: t.path).filter { $0.id != d.inst.id }
        let before = t.index < others.count ? others[t.index].id : nil
        if t.path == d.from {
            var proposed = others.map(\.id); proposed.insert(d.inst.id, at: min(t.index, others.count))
            if proposed == audio.instances(of: d.from).map(\.id) { return }
        }
        audio.moveInstance(d.inst.id, from: d.from, to: t.path, before: before)
        if selectedID == d.inst.id { audio.focusInstance(d.inst.id, in: t.path) }
        Haptics.impact(.light)
    }

    @ViewBuilder private var liftedTile: some View {
        if let d = drag, d.lifted, let cb = ChainBlock(d.inst.kind) {
            tileFace(cb, suffix: nil, on: audio.isEnabled(d.inst.id, in: d.from), selected: false)
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
                    Button {
                        if let nid = audio.addBlock(kind, in: id) { selectedID = nid; outputSelected = false; looperSelected = false }
                    } label: { Label(cb.full, systemImage: cb.icon) }
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
        return Button { looperSelected.toggle(); outputSelected = false; selectedID = nil } label: {
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
        Button { outputSelected.toggle(); selectedID = nil; looperSelected = false } label: {
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
    private var connector: some View { Rectangle().fill(.secondary.opacity(0.4)).frame(width: connectorW, height: 2) }
}
