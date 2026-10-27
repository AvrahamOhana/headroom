package com.avrahamohana.headroom.midi

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiInputPort
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.avrahamohana.headroom.engine.RigEngine
import com.avrahamohana.headroom.model.BlockKind
import com.avrahamohana.headroom.model.MidiOutMessage
import com.avrahamohana.headroom.model.MidiParam
import com.avrahamohana.headroom.model.Preset
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID

/** target: "presetNext" | "presetPrev" | "param:<MidiParam>" | "block:<BlockKind.raw>" | "looper" | "looperStop" | "tapTempo" | "mute" | "tuner" */
@Serializable
data class MidiMapping(
    val id: String = UUID.randomUUID().toString(),
    val cc: Int, val channel: Int? = null, val target: String,
    val source: String = "cc",            // cc | note
    val momentary: Boolean = true,
) {
    val isSwitch get() = !target.startsWith("param:")
    val label: String get() = when {
        target == "presetNext" -> "Next preset"; target == "presetPrev" -> "Previous preset"
        target.startsWith("param:") -> runCatching { MidiParam.valueOf(target.removePrefix("param:")).label }.getOrDefault(target)
        target.startsWith("block:") -> "${target.removePrefix("block:")} on/off"
        target == "looper" -> "Looper REC/Play/Dub"; target == "looperStop" -> "Looper stop"
        target == "tapTempo" -> "Tap tempo"; target == "mute" -> "Mute"; target == "tuner" -> "Tuner"
        else -> target
    }
}

@Serializable
data class MidiSaved(
    val mappings: List<MidiMapping> = emptyList(), val channelFilter: Int? = null, val outChannel: Int = 1,
    val sendPCOnPresetLoad: Boolean = true, val sendCCFeedback: Boolean = true, val sendClock: Boolean = false,
    val clockInSync: Boolean = true, val bankSelect: Boolean = false,
)

class MidiController(private val ctx: Context, private val rig: RigEngine) {
    private val mm = ctx.getSystemService(MidiManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val file = File(ctx.filesDir, "midi.json")

    val mappings = mutableStateListOf<MidiMapping>()
    @set:JvmName("_set_channelFilter") var channelFilter by mutableStateOf<Int?>(null); private set
    @set:JvmName("_set_outChannel") var outChannel by mutableIntStateOf(1); private set
    var sendPCOnPresetLoad by mutableStateOf(true); private set
    var sendCCFeedback by mutableStateOf(true); private set
    @set:JvmName("_set_sendClock") var sendClock by mutableStateOf(false); private set
    var clockInSync by mutableStateOf(true); private set
    @set:JvmName("_set_bankSelect") var bankSelect by mutableStateOf(false); private set
    var learnId by mutableStateOf<String?>(null)
    var activity by mutableIntStateOf(0); private set
    var lastMessage by mutableStateOf("—"); private set
    var lastSent by mutableStateOf("—"); private set
    var externalBpm by mutableStateOf<Double?>(null); private set
    val devices = mutableStateListOf<String>()
    val bleFound = mutableStateListOf<BluetoothDevice>()
    var bleScanning by mutableStateOf(false); private set

    private class Open(val device: MidiDevice, val outs: List<MidiOutputPort>, val ins: List<MidiInputPort>)
    private val open = mutableMapOf<Int, Open>()
    private var pendingBank = 0
    private var suppressFeedback = false
    private var clockJob: Job? = null
    // clock-in (MIDI thread)
    @Volatile private var clockTicks = 0
    @Volatile private var lastBeatNs = 0L
    @Volatile private var bpmAvg = 0.0

    init {
        runCatching { json.decodeFromString<MidiSaved>(file.readText()) }.getOrNull()?.let { s ->
            mappings.addAll(s.mappings); channelFilter = s.channelFilter; outChannel = s.outChannel
            sendPCOnPresetLoad = s.sendPCOnPresetLoad; sendCCFeedback = s.sendCCFeedback; sendClock = s.sendClock
            clockInSync = s.clockInSync; bankSelect = s.bankSelect
        }
        rig.onPresetLoaded = { i, p -> presetLoaded(i, p) }
        rig.onParamChanged = { p, n -> paramMoved(p, n) }
    }

    private fun persist() {
        val s = MidiSaved(mappings.toList(), channelFilter, outChannel, sendPCOnPresetLoad, sendCCFeedback, sendClock, clockInSync, bankSelect)
        runCatching { file.writeText(json.encodeToString(MidiSaved.serializer(), s)) }
    }
    fun setChannelFilter(v: Int?) { channelFilter = v; persist() }
    fun setOutChannel(v: Int) { outChannel = v; persist() }
    fun setSendPC(v: Boolean) { sendPCOnPresetLoad = v; persist() }
    fun setSendFeedback(v: Boolean) { sendCCFeedback = v; persist() }
    fun setSendClock(v: Boolean) { sendClock = v; persist(); updateClock() }
    fun setClockIn(v: Boolean) { clockInSync = v; persist() }
    fun setBankSelect(v: Boolean) { bankSelect = v; persist() }

    // ------------------------------------------------------------ devices
    private val cb = object : MidiManager.DeviceCallback() {
        override fun onDeviceAdded(info: MidiDeviceInfo) = openDevice(info)
        override fun onDeviceRemoved(info: MidiDeviceInfo) { open.remove(info.id)?.let { closeOpen(it) }; refreshNames() }
    }
    fun start() {
        if (mm == null) return
        @Suppress("DEPRECATION") mm.registerDeviceCallback(cb, main)
        @Suppress("DEPRECATION") mm.devices.forEach { openDevice(it) }
        updateClock()
    }
    fun stop() {
        if (mm == null) return
        mm.unregisterDeviceCallback(cb)
        open.values.forEach { closeOpen(it) }; open.clear(); devices.clear()
        clockJob?.cancel()
    }
    private fun closeOpen(o: Open) { runCatching { o.outs.forEach { it.close() }; o.ins.forEach { it.close() }; o.device.close() } }

    private fun openDevice(info: MidiDeviceInfo) {
        if (open.containsKey(info.id)) return
        if (info.properties.getString(MidiDeviceInfo.PROPERTY_MANUFACTURER) == "Headroom") return
        mm?.openDevice(info, { dev -> dev?.let { attach(it) } }, main)
    }
    private fun attach(dev: MidiDevice) {
        val info = dev.info
        val receiver = object : MidiReceiver() {
            override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) = parse(msg, offset, count)
        }
        val outs = (0 until info.outputPortCount).mapNotNull { dev.openOutputPort(it)?.also { p -> p.connect(receiver) } }
        val ins = (0 until info.inputPortCount).mapNotNull { dev.openInputPort(it) }
        open[info.id] = Open(dev, outs, ins)
        refreshNames()
    }
    private fun refreshNames() {
        devices.clear()
        open.values.forEach { o ->
            val p = o.device.info.properties
            devices += (p.getString(MidiDeviceInfo.PROPERTY_NAME) ?: p.getString(MidiDeviceInfo.PROPERTY_PRODUCT) ?: "MIDI device") +
                if (o.device.info.type == MidiDeviceInfo.TYPE_BLUETOOTH) " (BLE)" else ""
        }
    }

    // ------------------------------------------------------------ Bluetooth LE MIDI
    private val bleScanCb = object : ScanCallback() {
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            main.post { if (bleFound.none { it.address == result.device.address }) bleFound += result.device }
        }
    }
    @SuppressLint("MissingPermission")
    fun startBleScan() {
        val sc = ctx.getSystemService(BluetoothManager::class.java)?.adapter?.bluetoothLeScanner ?: return
        bleFound.clear(); bleScanning = true
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(UUID.fromString("03B80E5A-EDE8-4B33-A751-6CE34EC4C700"))).build()
        runCatching { sc.startScan(listOf(filter), ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), bleScanCb) }
            .onFailure { bleScanning = false; Log.w("HeadroomMidi", "BLE scan failed", it) }
        main.postDelayed({ stopBleScan() }, 15000)
    }
    @SuppressLint("MissingPermission")
    fun stopBleScan() {
        if (!bleScanning) return
        runCatching { ctx.getSystemService(BluetoothManager::class.java)?.adapter?.bluetoothLeScanner?.stopScan(bleScanCb) }
        bleScanning = false
    }
    fun connectBle(d: BluetoothDevice) { stopBleScan(); mm?.openBluetoothDevice(d, { dev -> dev?.let { attach(it) } }, main) }

    // ------------------------------------------------------------ input
    private var running = 0
    private val data = IntArray(2); private var dataN = 0
    /** MIDI thread: byte-stream parser with running status. */
    private fun parse(b: ByteArray, off: Int, count: Int) {
        for (i in off until off + count) {
            val v = b[i].toInt() and 0xFF
            if (v >= 0xF8) { realtime(v); continue }
            if (v >= 0x80) { running = if (v < 0xF0) v else 0; dataN = 0; continue }
            if (running == 0) continue
            data[dataN++] = v
            val hi = running and 0xF0
            val need = if (hi == 0xC0 || hi == 0xD0) 1 else 2
            if (dataN >= need) {
                val st = running; val d1 = data[0]; val d2 = if (need == 2) data[1] else 0
                dataN = 0
                if (hi == 0xB0 || hi == 0xC0 || hi == 0x90 || hi == 0x80) main.post { handle(st and 0xF0, st and 0x0F, d1, d2) }
            }
        }
    }
    private fun realtime(v: Int) {
        when (v) {
            0xF8 -> {
                if (++clockTicks < 24) return
                clockTicks = 0
                val now = System.nanoTime(); val last = lastBeatNs; lastBeatNs = now
                if (last == 0L) return
                val bpm = 60e9 / (now - last)
                if (bpm <= 20 || bpm >= 300) return
                bpmAvg = if (bpmAvg == 0.0) bpm else bpmAvg * 0.7 + bpm * 0.3
                val b = bpmAvg
                main.post { externalBpm = b; if (clockInSync && kotlin.math.abs(rig.bpm - b) > 0.5) rig.setBpm(b) }
            }
            0xFA, 0xFC -> { clockTicks = 0; lastBeatNs = 0; bpmAvg = 0.0 }
        }
    }

    private fun handle(hi: Int, ch: Int, d1: Int, d2: Int) {
        activity++
        lastMessage = if (hi == 0xC0) "PC $d1 · ch ${ch + 1}" else "${if (hi == 0xB0) "CC" else "Note"} $d1 = $d2 · ch ${ch + 1}"
        learnId?.let { lid ->
            if (hi == 0xB0 || hi == 0x90) {
                if (hi == 0x90 && d2 == 0) return
                val i = mappings.indexOfFirst { it.id == lid }
                if (i >= 0) { mappings[i] = mappings[i].copy(cc = d1, source = if (hi == 0x90) "note" else "cc", channel = channelFilter); persist() }
                learnId = null
            }
            return
        }
        channelFilter?.let { if (it - 1 != ch) return }
        if (hi == 0xB0 && bankSelect && (d1 == 0 || d1 == 32)) { pendingBank = if (d1 == 32) d2 else d2 * 128; return }
        if (hi == 0xC0) { suppressFeedback = true; rig.loadPreset(if (bankSelect) pendingBank + d1 else d1); suppressFeedback = false; return }
        val isNote = hi == 0x90 || hi == 0x80
        val value = if (hi == 0x80) 0 else d2
        mappings.filter { it.cc == d1 && (it.source == "note") == isNote && (it.channel == null || it.channel - 1 == ch) }.forEach { fire(it, value) }
    }

    private fun fire(m: MidiMapping, value: Int) {
        if (m.target.startsWith("param:")) {
            val p = runCatching { MidiParam.valueOf(m.target.removePrefix("param:")) }.getOrNull() ?: return
            suppressFeedback = true; rig.setMidiParam(p, value / 127.0); suppressFeedback = false
            return
        }
        val pressed = value >= 64
        if (m.momentary && !pressed) return
        when {
            m.target == "presetNext" -> rig.nextPreset()
            m.target == "presetPrev" -> rig.prevPreset()
            m.target.startsWith("block:") -> BlockKind.fromRaw(m.target.removePrefix("block:"))?.let { k ->
                rig.midiSetBlockOn(k, if (m.momentary) !rig.midiIsBlockOn(k) else pressed)
            }
            m.target == "looper" -> rig.looperToggle()
            m.target == "looperStop" -> rig.looperStop()
            m.target == "tapTempo" -> rig.tapTempo()
            m.target == "mute" -> if (m.momentary) rig.toggleMute() else rig.setMuted(pressed)
            m.target == "tuner" -> rig.tunerRequested = if (m.momentary) !rig.tunerRequested else pressed
        }
    }

    // ------------------------------------------------------------ output
    private fun presetLoaded(i: Int, p: Preset) {
        if (sendPCOnPresetLoad && !suppressFeedback) {
            if (bankSelect) sendCC(0, i / 128, outChannel)
            sendPC(i % 128, outChannel)
        }
        p.midiOut.forEach { send(it) }
    }
    private fun paramMoved(p: MidiParam, norm: Double) {
        if (!sendCCFeedback || suppressFeedback) return
        mappings.filter { it.source == "cc" && it.target == "param:${p.name}" }.forEach { sendCC(it.cc, (norm * 127).toInt(), it.channel ?: outChannel) }
    }
    fun send(m: MidiOutMessage) = if (m.kind == "controlChange") sendCC(m.number, m.value, m.channel) else sendPC(m.number, m.channel)
    fun sendPC(program: Int, channel: Int) { emit(byteArrayOf((0xC0 or ((channel - 1) and 0xF)).toByte(), (program and 0x7F).toByte())); lastSent = "PC $program · ch $channel" }
    fun sendCC(cc: Int, value: Int, channel: Int) {
        emit(byteArrayOf((0xB0 or ((channel - 1) and 0xF)).toByte(), (cc and 0x7F).toByte(), value.coerceIn(0, 127).toByte()))
        lastSent = "CC $cc = $value · ch $channel"
    }
    private fun emit(bytes: ByteArray) { open.values.forEach { o -> o.ins.forEach { runCatching { it.send(bytes, 0, bytes.size) } } } }

    private fun updateClock() {
        clockJob?.cancel(); clockJob = null
        if (!sendClock) return
        clockJob = rig.scope.launch {
            var next = System.nanoTime()
            while (isActive) {
                emit(byteArrayOf(0xF8.toByte()))
                next += (60e9 / rig.bpm.coerceAtLeast(20.0) / 24).toLong()
                delay(((next - System.nanoTime()) / 1_000_000).coerceAtLeast(1))
            }
        }
    }

    // ------------------------------------------------------------ mapping edits
    fun addMapping(target: String) {
        val used = mappings.filter { it.source == "cc" }.map { it.cc }.toSet()
        mappings += MidiMapping(cc = (1..127).firstOrNull { it !in used } ?: 1, channel = channelFilter, target = target); persist()
    }
    fun updateMapping(m: MidiMapping) { val i = mappings.indexOfFirst { it.id == m.id }; if (i >= 0) { mappings[i] = m; persist() } }
    fun removeMapping(id: String) { mappings.removeAll { it.id == id }; persist() }
}
