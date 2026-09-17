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
import os

private let dragLog = Logger(subsystem: "Headroom", category: "drag")

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
    @Environment(\.colorScheme) private var scheme
    private let tileW: CGFloat = 58, tileH: CGFloat = 74
    private let spacing: CGFloat = 4, connectorW: CGFloat = 6
    private var pitch: CGFloat { tileW + connectorW + 2 * spacing }
    private let space = "chainStrip"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("SIGNAL CHAIN").font(.caption.bold()).foregroundStyle(.secondary)
                #if os(macOS)
                Text(audio.dualOn ? "drag tiles · rows A and B" : "drag tiles to reorder").font(.caption2).foregroundStyle(.tertiary)
                #else
                Text(audio.dualOn ? "hold a tile to drag · rows A and B" : "hold a tile to drag").font(.caption2).foregroundStyle(.tertiary)
                #endif
                Spacer()
                Button { audio.dualOn.toggle(); Haptics.impact(.medium) } label: {
                    Label(audio.dualOn ? "A ∥ B" : "Dual", systemImage: audio.dualOn ? "rectangle.split.1x2.fill" : "rectangle.split.1x2")
                        .font(.caption.bold())
                }.buttonStyle(.plain).foregroundStyle(audio.dualOn ? .cyan : .secondary)
                Button { showReorder = true } label: {
                    Label("List", systemImage: "list.bullet").font(.caption.bold())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
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
            .padding(.vertical, 8).padding(.horizontal, 6)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(scheme == .dark ? Color.black.opacity(0.28) : Color.black.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.12)))
            }
        }
        .coordinateSpace(name: space)
        .onPreferenceChange(TileFramesKey.self) { [frames] v in frames.tiles = v }
        .onPreferenceChange(RowFramesKey.self) { [frames] v in frames.rows = v }
        .overlay(alignment: .topLeading) { liftedTile }
    }

    // MARK: rows

    /// A row slot: an instance, or the cross-row placeholder gap.
    private enum Slot: Identifiable {
        case inst(BlockInstance), gap
        var id: String { switch self { case .inst(let b): return b.id.uuidString; case .gap: return "gap" } }
    }

    /// What a row DISPLAYS while dragging. The dragged tile's VIEW must survive the whole gesture
    /// (it owns the DragGesture — removing it orphans the gesture and `onEnded` never fires), so:
    /// same-row target → the dragged instance is moved to its proposed slot and drawn as the gap;
    /// other-row target → it stays in its row collapsed to zero width, and the target row shows a
    /// separate `.gap` placeholder.
    private func displayOrder(_ id: RigPathID) -> [Slot] {
        var items = audio.instances(of: id)
        guard let d = drag, d.lifted else { return items.map { .inst($0) } }
        if let t = d.target, t.path == id, d.from == id {
            items.removeAll { $0.id == d.inst.id }
            items.insert(d.inst, at: min(t.index, items.count))
            return items.map { .inst($0) }
        }
        var slots: [Slot] = items.map { .inst($0) }
        if let t = d.target, t.path == id { slots.insert(.gap, at: min(t.index, slots.count)) }
        return slots
    }

    private func pathRow(_ id: RigPathID) -> some View {
        let order = displayOrder(id)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                endLabel(audio.dualOn ? id.label : "IN")
                ForEach(order) { slot in
                    switch slot {
                    case .gap:
                        connector
                        gap
                    case .inst(let inst):
                        if let cb = ChainBlock(inst.kind) {
                            let dragged = drag?.lifted == true && drag?.inst.id == inst.id
                            let parked = dragged && drag?.target?.path != id          // targeting the other row
                            if !parked { connector }
                            tile(inst, cb, in: id, dragged: dragged, parked: parked)
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: TileFramesKey.self, value: [inst.id: g.frame(in: .named(space))])
                                })
                        }
                    }
                }
                connector
                addTile(id)
            }
            .padding(.vertical, 2)
            .background(alignment: .leading) {   // the cable
                Capsule().fill(scheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.35))
                    .frame(height: 3).padding(.leading, 30).padding(.trailing, 60)
            }
            .animation(.snappy(duration: 0.22), value: order.map(\.id))
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
    }

    // MARK: tiles

    /// A stompbox: colored chassis with a top bevel, status LED, icon, name, and a glance readout.
    private func tileFace(_ block: ChainBlock, suffix: String?, on: Bool, selected sel: Bool, readout: String = "", art: Image? = nil) -> some View {
        let body = on ? block.color : Color(white: 0.28)
        return VStack(spacing: 3) {
            HStack {
                LED(on: on, color: on ? .green : .red, size: 7)
                Spacer()
                Text(suffix ?? "").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 6).padding(.top, 5)
            ZStack {
                if let art {
                    art.resizable().scaledToFill().frame(width: 30, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
                        .opacity(on ? 1 : 0.4)
                } else {
                    Image(systemName: block.icon).font(.system(size: 19, weight: .semibold))
                }
            }
            .frame(height: 24)
            Text(block.short).font(.system(size: 9.5, weight: .heavy)).tracking(0.5)
            Text(readout).font(.system(size: 7.5, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: tileW - 8)
                .foregroundStyle(on ? Stage.displayInk : .white.opacity(0.45))
                .padding(.bottom, 4)
        }
        .frame(width: tileW, height: tileH)
        .foregroundStyle(on ? .white : .white.opacity(0.45))
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [body.opacity(0.95), body.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 12).strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.35), lineWidth: 1).padding(-1)
            }
            .shadow(color: .black.opacity(on ? 0.45 : 0.25), radius: 5, y: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(sel ? .white : .clear, lineWidth: 2))
        .overlay(alignment: .bottom) {   // stomp switch cap
            Circle().fill(LinearGradient(colors: [.white.opacity(0.35), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom))
                .frame(width: 6, height: 6).offset(y: -1.5).opacity(0)
        }
    }

    /// `dragged`: this is the lifted tile → draw its slot as the gap. `parked`: the lifted tile is
    /// targeting the OTHER row → collapse it so this row closes up. Either way the view (and its
    /// gesture) stays alive.
    private func tile(_ inst: BlockInstance, _ block: ChainBlock, in id: RigPathID, dragged: Bool = false, parked: Bool = false) -> some View {
        let on = audio.isEnabled(inst.id, in: id), sel = selectedID == inst.id
        let art = inst.kind == .amp ? audio.artwork(for: inst.id, in: id).flatMap { Image(file: $0) } : nil
        return tileFace(block, suffix: audio.label(for: inst.id, in: id), on: on, selected: sel, readout: audio.readout(for: inst.id, in: id), art: art)
            .opacity(dragged ? 0 : 1)
            .overlay { if dragged && !parked { gap } }
            .frame(width: parked ? 0 : tileW)
            .clipped()
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                audio.focusInstance(inst.id, in: id)
                selectedID = sel ? nil : inst.id; outputSelected = false; looperSelected = false
            }
            .gesture(dragGesture(inst, in: id))
    }

    /// macOS: a mouse drag starts immediately (it doesn't fight trackpad scrolling). iOS: a short,
    /// jitter-tolerant hold first so the row can still scroll with a plain swipe.
    private func dragGesture(_ inst: BlockInstance, in id: RigPathID) -> some Gesture {
        #if os(macOS)
        DragGesture(minimumDistance: 6, coordinateSpace: .named(space))
            .onChanged { g in update(g, inst, id) }
            .onEnded { _ in commitDrag() }
        #else
        LongPressGesture(minimumDuration: 0.1, maximumDistance: 60)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(space)))
            .onChanged { value in if case .second(true, let g?) = value { update(g, inst, id) } }
            .onEnded { _ in commitDrag() }
        #endif
    }

    private func update(_ g: DragGesture.Value, _ inst: BlockInstance, _ id: RigPathID) {
                if let d = drag, d.inst.id != inst.id { drag = nil }        // stale state from an aborted gesture
                if drag == nil {
                    dragLog.debug("lift \(inst.kind.rawValue)")
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
                if drag?.lifted == false { drag?.lifted = true }
                retarget(g.location)
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
            drag?.target = new
        }
    }

    private func commitDrag() {
        guard let d = drag else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { dragLog.debug("commitDrag total \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms") }
        drag = nil
        guard let t = d.target else { return }
        let others = audio.instances(of: t.path).filter { $0.id != d.inst.id }
        let before = t.index < others.count ? others[t.index].id : nil
        if t.path == d.from {
            var proposed = others.map(\.id); proposed.insert(d.inst.id, at: min(t.index, others.count))
            if proposed == audio.instances(of: d.from).map(\.id) { return }
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        audio.moveInstance(d.inst.id, from: d.from, to: t.path, before: before)
        dragLog.debug("moveInstance \(Int((CFAbsoluteTimeGetCurrent() - t1) * 1000)) ms")
        if selectedID == d.inst.id { audio.focusInstance(d.inst.id, in: t.path) }
        Haptics.impact(.light)
    }

    @ViewBuilder private var liftedTile: some View {
        if let d = drag, d.lifted, let cb = ChainBlock(d.inst.kind) {
            tileFace(cb, suffix: nil, on: audio.isEnabled(d.inst.id, in: d.from), selected: false, readout: audio.readout(for: d.inst.id, in: d.from))
                .scaleEffect(1.08)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                .opacity(d.target == nil ? 0.5 : 1)
                .position(x: d.location.x - d.grabOffset.width, y: d.location.y - d.grabOffset.height)
                .allowsHitTesting(false)
        }
    }

    private func addTile(_ id: RigPathID) -> some View {
        let avail = audio.availableToAdd(in: id)
        return PlainMenu {
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
            .background(unitChassis(active ? .green : Color(red: 0.15, green: 0.45, blue: 0.25)))
            .overlay(alignment: .topLeading) { LED(on: active, color: .red, size: 7).padding(6) }
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
            .background(unitChassis(Color(red: 0.15, green: 0.5, blue: 0.75)))
            .overlay(alignment: .topLeading) { LED(on: audio.state == .running && !audio.muted, color: .green, size: 7).padding(6) }
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(outputSelected ? .white : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    /// Jack + label at the row ends.
    private func endLabel(_ t: String) -> some View {
        VStack(spacing: 3) {
            Circle().fill(LinearGradient(colors: [.white.opacity(0.5), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().fill(.black.opacity(0.7)).frame(width: 5, height: 5))
                .frame(width: 12, height: 12)
            Text(t).font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(.secondary)
        }
        .frame(width: 26, height: tileH)
    }
    private var connector: some View { Rectangle().fill(.clear).frame(width: connectorW, height: 2) }
    private func unitChassis(_ c: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [c.opacity(0.95), c.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 12).strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 5, y: 3)
    }
}
