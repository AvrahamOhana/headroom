package com.avrahamohana.headroom.engine

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.SystemClock
import android.provider.OpenableColumns
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.avrahamohana.headroom.audio.NativeEngine
import com.avrahamohana.headroom.audio.TempoClock
import com.avrahamohana.headroom.audio.WavLoader
import com.avrahamohana.headroom.model.BlockInstance
import com.avrahamohana.headroom.model.BlockKind
import com.avrahamohana.headroom.model.BlockParams
import com.avrahamohana.headroom.model.MidiOutMessage
import com.avrahamohana.headroom.model.MidiParam
import com.avrahamohana.headroom.model.NoteDivision
import com.avrahamohana.headroom.model.ParamSpec
import com.avrahamohana.headroom.model.Params
import com.avrahamohana.headroom.model.PathId
import com.avrahamohana.headroom.model.PathState
import com.avrahamohana.headroom.model.Preset
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

private const val TAG = "Headroom"

data class ToneModel(
    val id: String, val name: String, val path: String, val bundled: Boolean,
    val artworkPath: String? = null, val gear: String? = null,
) {
    val isAmpish get() = gear?.lowercase()?.contains("amp") ?: true
    val isPedalish get() = gear?.lowercase()?.contains("pedal") ?: true
}

/** Native handle + what is loaded into it (not observable). */
private class Runtime(val handle: Long, val kind: BlockKind) {
    var modelId: String? = null
    var irFile: String? = null
    var irRate = 0
}

class RigEngine(private val ctx: Context) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val json = Json { ignoreUnknownKeys = true; coerceInputValues = true; encodeDefaults = true; prettyPrint = false }

    val modelsDir = File(ctx.filesDir, "Models").apply { mkdirs() }
    val irsDir = File(ctx.filesDir, "IRs").apply { mkdirs() }
    private val bundledDir = File(ctx.filesDir, "Bundled").apply { mkdirs() }
    private val presetFile = File(ctx.filesDir, "presets.json")
    private val prefs = ctx.getSharedPreferences("headroom", Context.MODE_PRIVATE)

    // ------------------------------------------------------------------ observable state
    var pathA by mutableStateOf(PathState()); private set
    var pathB by mutableStateOf(PathState()); private set
    fun path(id: PathId) = if (id == PathId.A) pathA else pathB

    var dualOn by mutableStateOf(false); private set
    @set:JvmName("_set_levelA") var levelA by mutableStateOf(0.0); private set
    @set:JvmName("_set_levelB") var levelB by mutableStateOf(0.0); private set
    @set:JvmName("_set_panA") var panA by mutableStateOf(-0.7); private set
    @set:JvmName("_set_panB") var panB by mutableStateOf(0.7); private set
    var outputDb by mutableStateOf(-6.0); private set
    @set:JvmName("_set_muted") var muted by mutableStateOf(false); private set
    var stereoOn by mutableStateOf(false); private set
    var stereoPingMix by mutableStateOf(25.0); private set
    var stereoPingTime by mutableStateOf(350.0); private set
    var stereoPingFb by mutableStateOf(30.0); private set
    var stereoSpace by mutableStateOf(18.0); private set
    var stereoWidth by mutableStateOf(100.0); private set
    @set:JvmName("_set_loopLevel") var loopLevel by mutableStateOf(100.0); private set
    @set:JvmName("_set_bpm") var bpm by mutableStateOf(120.0); private set

    val presets = mutableStateListOf<Preset>()
    var currentPresetIndex by mutableIntStateOf(0); private set
    val currentPresetName get() = presets.getOrNull(currentPresetIndex)?.name ?: "Init"

    val models = mutableStateListOf<ToneModel>()
    val status = mutableStateMapOf<String, String>()      // instance id → model/IR status line
    var running by mutableStateOf(false); private set
    var lastError by mutableStateOf<String?>(null)
    var looperState by mutableIntStateOf(0); private set
    var looperHasLoop by mutableStateOf(false); private set

    // meters (polled)
    var inPeakDb by mutableFloatStateOf(-120f); private set
    var outPeakDb by mutableFloatStateOf(-120f); private set
    var cpuPercent by mutableIntStateOf(0); private set
    var tunerNote by mutableStateOf("—"); private set
    var tunerCents by mutableIntStateOf(0); private set
    var tunerActive by mutableStateOf(false); private set
    var tunerRequested by mutableStateOf(false)
    var audioInfo by mutableStateOf(AudioInfo()); private set

    data class AudioInfo(
        val sampleRate: Int = 0, val burst: Int = 0, val bufferFrames: Int = 0, val underruns: Int = 0,
        val latencyMs: Float = -1f, val exclusive: Boolean = false, val lowLatency: Boolean = false, val mmap: Boolean = false,
        val inputChannels: Int = 0,
    ) {
        val bufferMs get() = if (sampleRate > 0) bufferFrames * 1000f / sampleRate else 0f
    }

    // settings
    var burstsPerBuffer by mutableIntStateOf(prefs.getInt("bursts", 2)); private set
    var inputDeviceName by mutableStateOf(prefs.getString("inDev", null)); private set
    var outputDeviceName by mutableStateOf(prefs.getString("outDev", null)); private set
    @set:JvmName("_set_appearance") var appearance by mutableIntStateOf(prefs.getInt("appearance", 0))   // 0 system · 1 light · 2 dark
        private set
    fun setAppearance(v: Int) { appearance = v; prefs.edit().putInt("appearance", v).apply() }

    /** Which path MIDI param/toggle mappings act on; null = the focused (selected) path. */
    var midiPath by mutableStateOf<PathId?>(PathId.A)
    var focusPath by mutableStateOf(PathId.A)
    /** Per path, which instance of a kind MIDI / "the" block refers to (last tapped). */
    private val focused = mutableMapOf<PathId, MutableMap<BlockKind, String>>(PathId.A to mutableMapOf(), PathId.B to mutableMapOf())

    // hooks for MIDI
    var onPresetLoaded: ((Int, Preset) -> Unit)? = null
    var onParamChanged: ((MidiParam, Double) -> Unit)? = null

    private val runtime = mutableMapOf<String, Runtime>()
    val tempo = TempoClock()
    private var sampleRate = 48000
    private var pollJob: Job? = null
    private var applying = false

    // Plugging / unplugging a USB interface re-routes audio: restart onto the new device.
    private var hotplugJob: Job? = null
    private val deviceCb = object : android.media.AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = maybeRestart(added)
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = maybeRestart(removed)
        private fun maybeRestart(d: Array<out AudioDeviceInfo>) {
            if (!running || d.none { it.type in usbTypes }) return
            hotplugJob?.cancel()
            hotplugJob = scope.launch { delay(600); if (running) restart() }
        }
    }

    init {
        ctx.getSystemService(AudioManager::class.java).registerAudioDeviceCallback(deviceCb, android.os.Handler(android.os.Looper.getMainLooper()))
        installBundledModels()
        refreshModels()
        loadPresets()
        applyGlobals()
        applyCurrentPreset()
    }

    // ================================================================== models
    private fun installBundledModels() {
        try {
            for (name in ctx.assets.list("models").orEmpty()) {
                val dst = File(bundledDir, name)
                if (!dst.exists() || dst.length() == 0L) ctx.assets.open("models/$name").use { i -> dst.outputStream().use { i.copyTo(it) } }
            }
        } catch (e: Exception) { Log.e(TAG, "bundled models", e) }
    }

    fun refreshModels() {
        val list = mutableListOf<ToneModel>()
        bundledDir.listFiles()?.filter { it.extension.equals("nam", true) }?.sortedBy { it.name }?.forEach {
            list += ToneModel(it.nameWithoutExtension, it.nameWithoutExtension, it.path, true, gear = "amp")
        }
        modelsDir.listFiles()?.filter { it.extension.equals("nam", true) }?.sortedBy { it.name.lowercase() }?.forEach { f ->
            val base = f.nameWithoutExtension
            val art = File(modelsDir, "$base.jpg").takeIf { it.exists() }?.path
            val gear = File(modelsDir, "$base.gear").takeIf { it.exists() }?.readText()?.trim()
            list += ToneModel(f.name, base, f.path, false, art, gear)
        }
        models.clear(); models.addAll(list)
    }
    val ampModels get() = models.filter { it.isAmpish }
    val pedalModels get() = models.filter { it.isPedalish }
    fun modelName(id: String) = models.firstOrNull { it.id == id }?.name ?: id.ifEmpty { "—" }
    private fun resolveAmpModel(id: String) = models.firstOrNull { it.id == id } ?: ampModels.firstOrNull() ?: models.firstOrNull()
    fun artworkFor(inst: BlockInstance): String? = when (inst.k) {
        BlockKind.AMP -> resolveAmpModel(inst.p.model)?.artworkPath
        BlockKind.PEDAL -> models.firstOrNull { it.id == inst.p.pedalModel }?.artworkPath
        else -> null
    }

    /** Copy a picked/downloaded .nam into the library. Returns the model id. */
    fun importModel(src: File, displayName: String, gear: String? = null, artworkUrl: String? = null): String? {
        val safe = displayName.replace('/', '-').let { if (it.endsWith(".nam", true)) it else "$it.nam" }
        val dst = File(modelsDir, safe)
        return try {
            src.copyTo(dst, overwrite = true)
            if (gear != null) File(modelsDir, dst.nameWithoutExtension + ".gear").writeText(gear)
            refreshModels()
            if (artworkUrl != null) scope.launch(Dispatchers.IO) {
                runCatching { java.net.URL(artworkUrl).openStream().use { i -> File(modelsDir, dst.nameWithoutExtension + ".jpg").outputStream().use { i.copyTo(it) } } }
                withContext(Dispatchers.Main) { refreshModels() }
            }
            dst.name
        } catch (e: Exception) { lastError = "Import failed: ${e.message}"; null }
    }
    fun importModel(uri: Uri): String? {
        val name = displayName(uri) ?: "Imported.nam"
        val tmp = File(ctx.cacheDir, "import.nam")
        return try {
            ctx.contentResolver.openInputStream(uri)!!.use { i -> tmp.outputStream().use { i.copyTo(it) } }
            importModel(tmp, name)
        } catch (e: Exception) { lastError = "Import failed: ${e.message}"; null }
    }
    fun deleteModel(id: String) {
        val m = models.firstOrNull { it.id == id } ?: return
        if (m.bundled) return
        File(m.path).delete()
        File(modelsDir, "${m.name}.jpg").delete(); File(modelsDir, "${m.name}.gear").delete()
        refreshModels()
    }

    fun displayName(uri: Uri): String? = runCatching {
        ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    }.getOrNull()

    /** Copy an IR (picker/download) into IRs/ and return its file name. */
    fun importIR(uri: Uri): String? {
        val name = displayName(uri) ?: "IR.wav"
        return try {
            ctx.contentResolver.openInputStream(uri)!!.use { i -> File(irsDir, name).outputStream().use { i.copyTo(it) } }
            name
        } catch (e: Exception) { lastError = "IR import failed: ${e.message}"; null }
    }
    fun importIR(file: File, name: String): String { file.copyTo(File(irsDir, name), overwrite = true); return name }

    // ================================================================== instances ↔ native
    private fun ensureRuntime(inst: BlockInstance): Runtime =
        runtime.getOrPut(inst.id) { Runtime(NativeEngine.nativeCreateBlock(inst.k.ordinal), inst.k).also { pushAll(inst, it) } }

    /** Publish both chains; create/destroy native blocks to match the instance lists. */
    private fun syncNative() {
        val all = (pathA.blocks + pathB.blocks)
        val ids = all.map { it.id }.toSet()
        for ((id, rt) in runtime.toMap()) if (id !in ids) { NativeEngine.nativeDestroyBlock(rt.handle); runtime.remove(id); status.remove(id) }
        NativeEngine.nativeSetChain(0, pathA.blocks.map { ensureRuntime(it).handle }.toLongArray())
        NativeEngine.nativeSetChain(1, pathB.blocks.map { ensureRuntime(it).handle }.toLongArray())
        for (p in PathId.entries) {
            val f = focused.getValue(p); val st = path(p)
            for (k in BlockKind.entries) if (st.blocks.none { it.id == f[k] }) st.blocks.firstOrNull { it.k == k }?.let { f[k] = it.id } ?: f.remove(k)
        }
    }

    private fun pushAll(inst: BlockInstance, rt: Runtime) {
        NativeEngine.nativeSetBypass(rt.handle, !inst.isOn)
        for (s in Params.of(inst.k)) pushParam(inst, rt, s)
        if (inst.k == BlockKind.DELAY) NativeEngine.nativeSetParam(rt.handle, NativeEngine.P_DLY_SNAP, 0f)
        loadAssets(inst, rt, force = false)
    }

    private fun effectiveValue(inst: BlockInstance, s: ParamSpec): Double =
        if (inst.k == BlockKind.DELAY && s.key == "delayTime" && inst.p.delaySync) tempo.ms(inst.p.delayDiv).coerceIn(50.0, 1000.0) else s.get(inst.p)

    private fun pushParam(inst: BlockInstance, rt: Runtime, s: ParamSpec) =
        NativeEngine.nativeSetParam(rt.handle, s.nativeId, effectiveValue(inst, s).toFloat())

    /** Models / IRs referenced by the params. Loads asynchronously; no-op if already loaded. */
    private fun loadAssets(inst: BlockInstance, rt: Runtime, force: Boolean) {
        when (inst.k) {
            BlockKind.AMP -> {
                val m = resolveAmpModel(inst.p.model)
                if (m == null) { status[inst.id] = "No models — import a .nam"; NativeEngine.nativeClearModel(rt.handle); rt.modelId = null; return }
                if (!force && rt.modelId == m.id) return
                rt.modelId = m.id; loadModelAsync(inst.id, rt, m, isAmp = true)
            }
            BlockKind.PEDAL -> {
                val m = models.firstOrNull { it.id == inst.p.pedalModel }
                if (m == null) { NativeEngine.nativeClearModel(rt.handle); rt.modelId = null; status[inst.id] = "— empty —"; return }
                if (!force && rt.modelId == m.id) return
                rt.modelId = m.id; loadModelAsync(inst.id, rt, m, isAmp = false)
            }
            BlockKind.CAB, BlockKind.IR_REVERB -> {
                val file = if (inst.k == BlockKind.CAB) inst.p.cabIR else inst.p.irReverbIR
                if (!force && rt.irFile == file && rt.irRate == sampleRate) return
                rt.irFile = file; rt.irRate = sampleRate
                if (file.isEmpty()) { NativeEngine.nativeSetIR(rt.handle, null); status[inst.id] = "None"; return }
                val f = File(irsDir, file); val sr = sampleRate; val cab = inst.k == BlockKind.CAB
                scope.launch(Dispatchers.IO) {
                    val taps = if (cab) WavLoader.cabIR(f, sr) else WavLoader.reverbIR(f, sr)
                    withContext(Dispatchers.Main) {
                        if (runtime[inst.id] !== rt || rt.irFile != file) return@withContext
                        if (taps == null) { status[inst.id] = "❌ IR load failed"; NativeEngine.nativeSetIR(rt.handle, null) }
                        else { NativeEngine.nativeSetIR(rt.handle, taps); status[inst.id] = f.nameWithoutExtension }
                    }
                }
            }
            else -> {}
        }
    }

    private fun loadModelAsync(instId: String, rt: Runtime, m: ToneModel, isAmp: Boolean) {
        status[instId] = "Loading ${m.name}…"
        scope.launch(Dispatchers.IO) {
            val res = runCatching { NativeEngine.nativeLoadModel(rt.handle, m.path) }
            withContext(Dispatchers.Main) {
                if (runtime[instId] !== rt || rt.modelId != m.id) return@withContext
                res.onSuccess { r ->
                    if (isAmp) {
                        NativeEngine.nativeSetParam(rt.handle, NativeEngine.P_AMP_MAKEUP, r[0].toFloat())
                        val how = if (r[1].isNaN()) "probe" else "loudness %.1f dB".format(r[1])
                        status[instId] = "${m.name} · $how · trim %+.0f dB".format(r[0])
                    } else status[instId] = m.name
                }.onFailure { status[instId] = "❌ Load failed: ${it.message}"; rt.modelId = null }
            }
        }
    }

    // ================================================================== editing
    fun instance(id: String): Pair<BlockInstance, PathId>? {
        pathA.blocks.firstOrNull { it.id == id }?.let { return it to PathId.A }
        pathB.blocks.firstOrNull { it.id == id }?.let { return it to PathId.B }
        return null
    }
    private fun setPath(id: PathId, st: PathState) { if (id == PathId.A) pathA = st else pathB = st }
    private fun mutate(instId: String, f: (BlockInstance) -> BlockInstance): BlockInstance? {
        val (old, pid) = instance(instId) ?: return null
        val new = f(old)
        setPath(pid, PathState(path(pid).blocks.map { if (it.id == instId) new else it }))
        return new
    }

    fun focus(instId: String) {
        val (inst, pid) = instance(instId) ?: return
        focusPath = pid; focused.getValue(pid)[inst.k] = instId
    }

    fun setParam(instId: String, spec: ParamSpec, value: Double) {
        val v = value.coerceIn(spec.min, spec.max)
        val inst = mutate(instId) { it.copy(p = spec.set(it.p, v)) } ?: return
        runtime[instId]?.let { pushParam(inst, it, spec) }
        if (!applying) MidiParam.entries.firstOrNull { it.kind == inst.k && it.key == spec.key }?.let { onParamChanged?.invoke(it, spec.norm(v)) }
    }
    /** Non-spec param edits (model, IR, sync, division…) → re-push the whole instance. */
    fun updateParams(instId: String, reloadAssets: Boolean = false, f: (BlockParams) -> BlockParams) {
        val inst = mutate(instId) { it.copy(p = f(it.p)) } ?: return
        val rt = runtime[instId] ?: return
        NativeEngine.nativeSetBypass(rt.handle, !inst.isOn)
        for (s in Params.of(inst.k)) pushParam(inst, rt, s)
        loadAssets(inst, rt, force = reloadAssets)
    }
    fun setEnabled(instId: String, on: Boolean) {
        val inst = mutate(instId) { it.copy(p = it.p.withOn(it.k, on)) } ?: return
        runtime[instId]?.let { NativeEngine.nativeSetBypass(it.handle, !on) }
        inst.k
    }
    fun meter(instId: String): Float = runtime[instId]?.let { NativeEngine.nativeGetMeter(it.handle) } ?: 0f

    fun selectReverbType(instId: String, t: Int) {
        val (dec, damp) = Params.reverbTypeDefaults(t)
        updateParams(instId) { it.copy(reverbType = t, reverbDecay = dec, reverbDamp = damp) }
    }

    fun countOf(pid: PathId, k: BlockKind) = path(pid).blocks.count { it.k == k }
    fun availableToAdd(pid: PathId) = BlockKind.entries.filter { countOf(pid, it) < MAX_PER_KIND }

    fun addBlock(k: BlockKind, pid: PathId): String? {
        if (countOf(pid, k) >= MAX_PER_KIND) return null
        val inst = BlockInstance.of(k)
        val list = path(pid).blocks.toMutableList()
        val ai = list.indexOfFirst { it.k == BlockKind.AMP }
        if (k.preAmp && ai >= 0) list.add(ai, inst) else list.add(inst)
        setPath(pid, PathState(list)); syncNative(); focus(inst.id)
        return inst.id
    }
    fun removeInstance(instId: String) {
        val (_, pid) = instance(instId) ?: return
        setPath(pid, PathState(path(pid).blocks.filter { it.id != instId })); syncNative()
    }
    fun reorder(pid: PathId, ids: List<String>) {
        val by = path(pid).blocks.associateBy { it.id }
        setPath(pid, PathState(ids.mapNotNull { by[it] } + path(pid).blocks.filter { it.id !in ids })); syncNative()
    }
    /** Move within a path or to the other path (settings travel). `beforeId` null = append. */
    fun moveInstance(instId: String, to: PathId, beforeId: String?) {
        val (inst, from) = instance(instId) ?: return
        if (from != to && countOf(to, inst.k) >= MAX_PER_KIND) return
        val src = path(from).blocks.filter { it.id != instId }
        if (from == to) {
            val l = src.toMutableList(); val j = l.indexOfFirst { it.id == beforeId }
            if (j >= 0) l.add(j, inst) else l.add(inst)
            setPath(from, PathState(l))
        } else {
            setPath(from, PathState(src))
            val l = path(to).blocks.toMutableList(); val j = l.indexOfFirst { it.id == beforeId }
            if (j >= 0) l.add(j, inst) else l.add(inst)
            setPath(to, PathState(l))
        }
        syncNative()
    }
    fun label(instId: String): String? {
        val (inst, pid) = instance(instId) ?: return null
        val same = path(pid).blocks.filter { it.k == inst.k }
        return if (same.size > 1) "${same.indexOfFirst { it.id == instId } + 1}" else null
    }

    fun readout(inst: BlockInstance): String {
        val p = inst.p
        return when (inst.k) {
            BlockKind.AMP -> resolveAmpModel(p.model)?.name ?: "—"
            BlockKind.PEDAL -> if (p.pedalModel.isEmpty()) "—" else modelName(p.pedalModel)
            BlockKind.CAB -> if (p.cabIR.isEmpty()) "no IR" else p.cabIR.substringBeforeLast('.')
            BlockKind.IR_REVERB -> if (p.irReverbIR.isEmpty()) "no IR" else p.irReverbIR.substringBeforeLast('.')
            BlockKind.GATE -> "${p.gateThr.roundToInt()} dB"
            BlockKind.COMP -> "%.0f:1".format(p.compRatio)
            BlockKind.BOOST -> "+%.0f dB".format(p.boostDb)
            BlockKind.DRIVE -> Params.driveModes[p.driveMode.coerceIn(0, 2)] + " ×${p.driveAmt.toInt()}"
            BlockKind.STOMP -> Params.stompNames[p.stompModel.coerceIn(0, 4)]
            BlockKind.WAH -> if (p.wahAuto) "Auto" else "${(p.wahPos * 100).roundToInt()}%"
            BlockKind.EQ -> "%+.0f %+.0f %+.0f".format(p.bass, p.mid, p.treble)
            BlockKind.CHORUS -> "%.1f Hz".format(p.chorusRate)
            BlockKind.FLANGER -> "%.1f Hz".format(p.flangerRate)
            BlockKind.TREMOLO -> "%.1f Hz".format(p.tremoloRate)
            BlockKind.DELAY -> if (p.delaySync) p.delayDiv.label else "${p.delayTime.roundToInt()} ms"
            BlockKind.REVERB -> Params.reverbTypes[p.reverbType.coerceIn(0, 3)]
        }
    }

    // ================================================================== globals
    private fun applyGlobals() {
        NativeEngine.nativeSetGlobal(NativeEngine.G_OUTPUT_DB, outputDb.toFloat())
        NativeEngine.nativeSetGlobal(NativeEngine.G_MUTED, if (muted) 1f else 0f)
        NativeEngine.nativeSetGlobal(NativeEngine.G_DUAL_ON, if (dualOn) 1f else 0f)
        NativeEngine.nativeSetGlobal(NativeEngine.G_LEVEL_A, levelA.toFloat()); NativeEngine.nativeSetGlobal(NativeEngine.G_LEVEL_B, levelB.toFloat())
        NativeEngine.nativeSetGlobal(NativeEngine.G_PAN_A, panA.toFloat()); NativeEngine.nativeSetGlobal(NativeEngine.G_PAN_B, panB.toFloat())
        NativeEngine.nativeSetGlobal(NativeEngine.G_STEREO_ON, if (stereoOn) 1f else 0f)
        NativeEngine.nativeSetGlobal(NativeEngine.G_PING_MIX, stereoPingMix.toFloat()); NativeEngine.nativeSetGlobal(NativeEngine.G_PING_TIME, stereoPingTime.toFloat())
        NativeEngine.nativeSetGlobal(NativeEngine.G_PING_FB, stereoPingFb.toFloat()); NativeEngine.nativeSetGlobal(NativeEngine.G_SPACE, stereoSpace.toFloat())
        NativeEngine.nativeSetGlobal(NativeEngine.G_WIDTH, stereoWidth.toFloat()); NativeEngine.nativeSetGlobal(NativeEngine.G_LOOP_LEVEL, loopLevel.toFloat())
    }
    fun setOutput(v: Double) { outputDb = v.coerceIn(-40.0, 12.0); NativeEngine.nativeSetGlobal(NativeEngine.G_OUTPUT_DB, outputDb.toFloat()); feedback(MidiParam.OUTPUT, (outputDb + 40) / 52) }
    fun toggleMute() = setMuted(!muted)
    fun setMuted(v: Boolean) { muted = v; NativeEngine.nativeSetGlobal(NativeEngine.G_MUTED, if (v) 1f else 0f) }
    fun setDual(v: Boolean) { dualOn = v; NativeEngine.nativeSetGlobal(NativeEngine.G_DUAL_ON, if (v) 1f else 0f); if (!v) focusPath = PathId.A }
    fun setLevelA(v: Double) { levelA = v; NativeEngine.nativeSetGlobal(NativeEngine.G_LEVEL_A, v.toFloat()); feedback(MidiParam.AMP_A_LEVEL, (v + 24) / 36) }
    fun setLevelB(v: Double) { levelB = v; NativeEngine.nativeSetGlobal(NativeEngine.G_LEVEL_B, v.toFloat()); feedback(MidiParam.AMP_B_LEVEL, (v + 24) / 36) }
    fun setPanA(v: Double) { panA = v; NativeEngine.nativeSetGlobal(NativeEngine.G_PAN_A, v.toFloat()) }
    fun setPanB(v: Double) { panB = v; NativeEngine.nativeSetGlobal(NativeEngine.G_PAN_B, v.toFloat()) }
    fun setStereo(v: Boolean) { stereoOn = v; NativeEngine.nativeSetGlobal(NativeEngine.G_STEREO_ON, if (v) 1f else 0f) }
    fun setPingMix(v: Double) { stereoPingMix = v; NativeEngine.nativeSetGlobal(NativeEngine.G_PING_MIX, v.toFloat()) }
    fun setPingTime(v: Double) { stereoPingTime = v; NativeEngine.nativeSetGlobal(NativeEngine.G_PING_TIME, v.toFloat()) }
    fun setPingFb(v: Double) { stereoPingFb = v; NativeEngine.nativeSetGlobal(NativeEngine.G_PING_FB, v.toFloat()) }
    fun setSpace(v: Double) { stereoSpace = v; NativeEngine.nativeSetGlobal(NativeEngine.G_SPACE, v.toFloat()) }
    fun setWidth(v: Double) { stereoWidth = v; NativeEngine.nativeSetGlobal(NativeEngine.G_WIDTH, v.toFloat()) }
    fun setLoopLevel(v: Double) { loopLevel = v; NativeEngine.nativeSetGlobal(NativeEngine.G_LOOP_LEVEL, v.toFloat()); feedback(MidiParam.LOOP_LEVEL, v / 100) }
    private fun feedback(p: MidiParam, n: Double) { if (!applying) onParamChanged?.invoke(p, n.coerceIn(0.0, 1.0)) }

    // tempo
    fun setBpm(v: Double) { tempo.bpm = v; bpm = tempo.bpm; resyncDelays() }
    fun tapTempo() { tempo.tap(SystemClock.elapsedRealtimeNanos() / 1e9); bpm = tempo.bpm; resyncDelays() }
    private fun resyncDelays() {
        for (inst in pathA.blocks + pathB.blocks) if (inst.k == BlockKind.DELAY && inst.p.delaySync) runtime[inst.id]?.let { rt ->
            Params.find(BlockKind.DELAY, "delayTime")?.let { pushParam(inst, rt, it) }
        }
    }
    fun setDelaySync(instId: String, on: Boolean) = updateParams(instId) { it.copy(delaySync = on) }
    fun setDelayDivision(instId: String, d: NoteDivision) = updateParams(instId) { it.copy(delayDiv = d) }

    // looper
    fun looperToggle() { NativeEngine.nativeLooper(0); refreshLooper() }
    fun looperStop() { NativeEngine.nativeLooper(1); refreshLooper() }
    fun looperClear() { NativeEngine.nativeLooper(2); refreshLooper() }
    private fun refreshLooper() { looperState = NativeEngine.nativeLooperState(); looperHasLoop = NativeEngine.nativeLooperHasLoop() }
    val looperStateLabel get() = listOf("Idle", "REC", "Play", "Overdub", "Stopped").getOrElse(looperState) { "Idle" }

    // ================================================================== MIDI entry points
    /** Focused instance of `kind` in the MIDI target path. */
    private fun midiTarget(k: BlockKind): BlockInstance? {
        val pid = midiPath ?: focusPath
        val st = path(pid)
        return st.blocks.firstOrNull { it.id == focused.getValue(pid)[k] } ?: st.blocks.firstOrNull { it.k == k }
    }
    fun setMidiParam(p: MidiParam, normalized: Double) {
        val n = normalized.coerceIn(0.0, 1.0)
        when (p) {
            MidiParam.OUTPUT -> setOutput(-40 + 52 * n)
            MidiParam.LOOP_LEVEL -> setLoopLevel(100 * n)
            MidiParam.AMP_A_LEVEL -> setLevelA(-24 + 36 * n)
            MidiParam.AMP_B_LEVEL -> setLevelB(-24 + 36 * n)
            else -> {
                val k = p.kind ?: return
                val inst = midiTarget(k) ?: return
                val spec = Params.find(k, p.key) ?: return
                setParam(inst.id, spec, spec.denorm(n))
            }
        }
    }
    fun midiParamNormalized(p: MidiParam): Double = when (p) {
        MidiParam.OUTPUT -> (outputDb + 40) / 52
        MidiParam.LOOP_LEVEL -> loopLevel / 100
        MidiParam.AMP_A_LEVEL -> (levelA + 24) / 36
        MidiParam.AMP_B_LEVEL -> (levelB + 24) / 36
        else -> { val k = p.kind; val inst = k?.let { midiTarget(it) }; val s = k?.let { Params.find(it, p.key) }
            if (inst != null && s != null) s.norm(s.get(inst.p)) else 0.0 }
    }
    fun midiIsBlockOn(k: BlockKind) = midiTarget(k)?.isOn ?: false
    fun midiSetBlockOn(k: BlockKind, on: Boolean) { midiTarget(k)?.let { setEnabled(it.id, on) } }

    // ================================================================== presets
    private fun loadPresets() {
        val list = runCatching { json.decodeFromString<List<Preset>>(presetFile.readText()) }.getOrNull()
        presets.clear(); presets.addAll(if (list.isNullOrEmpty()) Preset.defaults() else list)
        currentPresetIndex = prefs.getInt("presetIndex", 0).coerceIn(0, presets.size - 1)
    }
    private fun savePresets() {
        runCatching { presetFile.writeText(json.encodeToString(kotlinx.serialization.builtins.ListSerializer(Preset.serializer()), presets.toList())) }
            .onFailure { Log.e(TAG, "save presets", it) }
        prefs.edit().putInt("presetIndex", currentPresetIndex).apply()
    }
    fun applyCurrentPreset() { presets.getOrNull(currentPresetIndex)?.let { apply(it) } }
    fun loadPreset(i: Int) {
        val p = presets.getOrNull(i) ?: return
        currentPresetIndex = i; apply(p); prefs.edit().putInt("presetIndex", i).apply()
        onPresetLoaded?.invoke(i, p)
    }
    fun nextPreset() { if (presets.isNotEmpty()) loadPreset((currentPresetIndex + 1) % presets.size) }
    fun prevPreset() { if (presets.isNotEmpty()) loadPreset((currentPresetIndex - 1 + presets.size) % presets.size) }

    private fun apply(p: Preset) {
        applying = true
        try {
            // Fresh instance ids per load → fresh DSP state (tails cleared), like iOS's forced apply.
            fun fresh(st: PathState) = PathState(st.blocks.map { it.copy(id = java.util.UUID.randomUUID().toString().uppercase()) })
            pathA = fresh(p.a); pathB = fresh(p.b)
            focused.getValue(PathId.A).clear(); focused.getValue(PathId.B).clear()
            syncNative()
            dualOn = p.dualOn; levelA = p.levelA; levelB = p.levelB; panA = p.panA; panB = p.panB
            outputDb = p.output
            stereoOn = p.stereoOn; stereoPingMix = p.stereoPingMix; stereoPingTime = p.stereoPingTime
            stereoPingFb = p.stereoPingFb; stereoSpace = p.stereoSpace; stereoWidth = p.stereoWidth
            if (p.bpm > 0) { tempo.bpm = p.bpm; bpm = tempo.bpm; resyncDelays() }
            if (!dualOn) focusPath = PathId.A
            applyGlobals()
        } finally { applying = false }
    }
    private fun capture(name: String, keep: Preset? = null) = Preset(
        id = keep?.id ?: java.util.UUID.randomUUID().toString().uppercase(), name = name,
        a = pathA, b = pathB, dualOn = dualOn, levelA = levelA, levelB = levelB, panA = panA, panB = panB,
        output = outputDb, stereoOn = stereoOn, stereoPingMix = stereoPingMix, stereoPingTime = stereoPingTime,
        stereoPingFb = stereoPingFb, stereoSpace = stereoSpace, stereoWidth = stereoWidth, bpm = tempo.bpm,
        midiOut = keep?.midiOut ?: presets.getOrNull(currentPresetIndex)?.midiOut.orEmpty(),
    )
    fun saveCurrentAs(name: String) {
        presets.add(capture(name.ifBlank { "Preset ${presets.size + 1}" })); currentPresetIndex = presets.size - 1; savePresets()
    }
    fun overwriteCurrent() {
        val old = presets.getOrNull(currentPresetIndex) ?: return
        presets[currentPresetIndex] = capture(old.name, old); savePresets()
    }
    fun renamePreset(i: Int, name: String) { val n = name.trim(); if (n.isEmpty() || i !in presets.indices) return; presets[i] = presets[i].copy(name = n); savePresets() }
    fun duplicatePreset(i: Int) {
        val p = presets.getOrNull(i) ?: return
        presets.add(i + 1, p.copy(id = java.util.UUID.randomUUID().toString().uppercase(), name = p.name + " copy"))
        if (i < currentPresetIndex) currentPresetIndex++
        savePresets()
    }
    fun deletePreset(i: Int) {
        if (i !in presets.indices || presets.size <= 1) return
        presets.removeAt(i)
        if (currentPresetIndex >= presets.size) currentPresetIndex = presets.size - 1 else if (i < currentPresetIndex) currentPresetIndex--
        savePresets()
    }
    fun movePreset(from: Int, to: Int) {
        if (from !in presets.indices || to !in presets.indices || from == to) return
        val keepId = presets.getOrNull(currentPresetIndex)?.id
        val p = presets.removeAt(from); presets.add(to, p)
        currentPresetIndex = presets.indexOfFirst { it.id == keepId }.coerceAtLeast(0)
        savePresets()
    }
    var currentMidiOut: List<MidiOutMessage>
        get() = presets.getOrNull(currentPresetIndex)?.midiOut.orEmpty()
        set(v) { if (currentPresetIndex in presets.indices) { presets[currentPresetIndex] = presets[currentPresetIndex].copy(midiOut = v); savePresets() } }

    val bankIndex get() = currentPresetIndex / 4
    val sceneInBank get() = currentPresetIndex % 4
    fun tag(i: Int) = "${i / 4}${"ABCD"[((i % 4) + 4) % 4]}"
    val presetTag get() = tag(currentPresetIndex)

    // ================================================================== audio lifecycle
    fun setBursts(v: Int) { burstsPerBuffer = v; prefs.edit().putInt("bursts", v).apply(); if (running) restart() }
    fun setInputDevice(name: String?) { inputDeviceName = name; prefs.edit().putString("inDev", name).apply(); if (running) restart() }
    fun setOutputDevice(name: String?) { outputDeviceName = name; prefs.edit().putString("outDev", name).apply(); if (running) restart() }

    fun devices(input: Boolean): List<AudioDeviceInfo> {
        val am = ctx.getSystemService(AudioManager::class.java)
        return am.getDevices(if (input) AudioManager.GET_DEVICES_INPUTS else AudioManager.GET_DEVICES_OUTPUTS).toList()
    }
    fun deviceLabel(d: AudioDeviceInfo): String = "${d.productName} · ${typeName(d.type)}"
    private fun typeName(t: Int) = when (t) {
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> "built-in mic"; AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_ACCESSORY -> "USB"
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET -> "Bluetooth"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        else -> "type $t"
    }
    /** Re-evaluated on each audio (re)start. */
    var usbInput by mutableStateOf(false); private set
    fun hasUsbInput() = usbInput
    private val usbTypes = setOf(AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_ACCESSORY)
    private fun pickDevice(input: Boolean): Int {
        val list = devices(input)
        val name = if (input) inputDeviceName else outputDeviceName
        name?.let { n -> list.firstOrNull { deviceLabel(it) == n }?.let { return it.id } }
        // Default: prefer a USB interface (that's where the guitar is), else the system default.
        val usb = setOf(AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_ACCESSORY)
        return list.firstOrNull { it.type in usb }?.id ?: 0
    }

    fun start() {
        if (running) return
        lastError = null
        usbInput = devices(true).any { it.type in usbTypes }
        val err = NativeEngine.nativeStart(pickDevice(true), pickDevice(false), burstsPerBuffer, 48000)
        if (err != null) { lastError = err; running = false; return }
        running = true
        pollStats(once = true)
        val sr = audioInfo.sampleRate
        if (sr > 0 && sr != sampleRate) {
            sampleRate = sr
            for (inst in pathA.blocks + pathB.blocks) runtime[inst.id]?.let { loadAssets(inst, it, force = false) }   // IRs re-resample
        }
        startPolling()
    }
    fun stop() {
        pollJob?.cancel(); pollJob = null
        NativeEngine.nativeStop()
        running = false; tunerActive = false
        inPeakDb = -120f; outPeakDb = -120f
    }
    fun restart() { stop(); start() }
    fun toggle() = if (running) stop() else start()

    private val statsBuf = FloatArray(12)
    private val tunerBuf = FloatArray(2)
    private fun pollStats(once: Boolean = false) {
        NativeEngine.nativeStats(statsBuf)
        inPeakDb = toDb(statsBuf[0]); outPeakDb = toDb(statsBuf[1])
        cpuPercent = (statsBuf[2] * 100).roundToInt().coerceIn(0, 999)
        val info = AudioInfo(statsBuf[3].toInt(), statsBuf[4].toInt(), statsBuf[5].toInt(), statsBuf[6].toInt(), statsBuf[7],
            statsBuf[8] > 0.5f, statsBuf[9] > 0.5f, statsBuf[10] > 0.5f, statsBuf[11].toInt())
        if (info != audioInfo) audioInfo = info
        if (once) return
        val ls = NativeEngine.nativeLooperState(); if (ls != looperState) looperState = ls
        val hl = NativeEngine.nativeLooperHasLoop(); if (hl != looperHasLoop) looperHasLoop = hl
    }
    private var tick = 0
    private fun startPolling() {
        pollJob?.cancel()
        pollJob = scope.launch {
            while (isActive) {
                pollStats()
                if (++tick % 2 == 0) updateTuner()
                if (NativeEngine.nativeTakeDisconnected()) {
                    Log.w(TAG, "audio device disconnected → restart")
                    running = false; delay(300); start(); return@launch
                }
                delay(40)
            }
        }
    }
    private fun updateTuner() {
        if (NativeEngine.nativeTuner(tunerBuf)) {
            val midi = 69 + 12 * (kotlin.math.ln(tunerBuf[0] / 440.0) / kotlin.math.ln(2.0))
            val nearest = midi.roundToInt()
            tunerCents = ((midi - nearest) * 100).roundToInt()
            tunerNote = NOTE_NAMES[((nearest % 12) + 12) % 12] + (nearest / 12 - 1)
            tunerActive = true
        } else tunerActive = false
    }

    companion object {
        const val MAX_PER_KIND = 4
        val NOTE_NAMES = listOf("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")
        fun toDb(x: Float) = if (x > 1e-6f) (20 * log10(x)) else -120f
    }
}

@Suppress("unused") private fun clampD(v: Double, a: Double, b: Double) = max(a, min(b, v))
