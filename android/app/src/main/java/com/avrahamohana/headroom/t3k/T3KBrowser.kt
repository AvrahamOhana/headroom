package com.avrahamohana.headroom.t3k

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil.compose.AsyncImage
import com.avrahamohana.headroom.engine.RigEngine
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File

private val gears = listOf("All gear" to "", "Amp" to "amp", "Amp + Cab" to "amp-cab", "Pedal" to "pedal", "Cab" to "cab", "Outboard" to "outboard", "Full rig" to "full-rig")
private val archs = listOf("A2" to "2", "A1" to "1", "Custom" to "custom", "Any" to "")
private val sorts = listOf("Best match" to "best-match", "Trending" to "trending", "Newest" to "newest", "Most downloaded" to "downloads-all-time", "Oldest" to "oldest")
private val tabs = listOf("Search", "Trending", "Favorites", "Mine", "Downloaded")

/** TONE3000 capture browser. target: amp | pedal | cab. onDownloaded(file, displayName, gear, artworkUrl). */
@Composable
fun T3KBrowser(rig: RigEngine, client: T3KClient, target: String, onDownloaded: (File, String, String?, String?) -> Unit, onDismiss: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val isCab = target == "cab"
    var tab by remember { mutableIntStateOf(0) }
    var query by remember { mutableStateOf("") }
    var gear by remember { mutableStateOf(if (target == "pedal") "pedal" else if (isCab) "cab" else "amp-cab") }
    var arch by remember { mutableStateOf(if (isCab) "" else "2") }
    var sort by remember { mutableStateOf("best-match") }
    var calibrated by remember { mutableStateOf(false) }
    var verified by remember { mutableStateOf(false) }
    val tones = remember { mutableStateListOf<T3KTone>() }
    var loading by remember { mutableStateOf(false) }
    var page by remember { mutableIntStateOf(1) }
    var totalPages by remember { mutableIntStateOf(1) }
    var status by remember { mutableStateOf("") }
    var detail by remember { mutableStateOf<T3KTone?>(null) }
    var library by remember { mutableStateOf(client.library) }
    var reloadKey by remember { mutableIntStateOf(0) }

    suspend fun fetch(p: Int): T3KPage = when (tab) {
        0 -> client.search(query, gear, arch, sort, if (isCab) "" else "nam", calibrated, verified, p)
        1 -> client.trending(gear)
        2 -> client.userTones("favorited", gear, p)
        3 -> client.userTones("created", gear, p)
        else -> client.userTones("downloaded", gear, p)
    }
    LaunchedEffect(client.isLoggedIn, tab, gear, arch, sort, calibrated, verified, query, reloadKey) {
        if (!client.isLoggedIn) return@LaunchedEffect
        if (query.isNotEmpty()) delay(400)
        if (client.username == null) client.loadProfile()
        loading = true; status = ""
        try { val r = fetch(1); tones.clear(); tones.addAll(r.tones); page = 1; totalPages = r.totalPages }
        catch (e: Exception) { tones.clear(); status = e.message ?: "Error" }
        loading = false
    }

    Dialog(onDismiss, DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().systemBarsPadding()) {
                Row(Modifier.padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (detail != null) IconButton({ detail = null }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
                    Text(detail?.title ?: "TONE3000", fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f).padding(start = 8.dp), maxLines = 1)
                    if (client.isLoggedIn) TextButton(client::logout) { Text(client.username?.let { "@$it · Log out" } ?: "Log out", fontSize = 12.sp) }
                    TextButton(onDismiss) { Text("Done") }
                }
                when {
                    !client.isLoggedIn -> Column(Modifier.fillMaxSize().padding(40.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                        Icon(Icons.Filled.CloudDownload, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.primary)
                        Text("Connect your TONE3000 account to browse and download captures.", color = Color.Gray, modifier = Modifier.padding(16.dp))
                        Button({ client.beginLogin(ctx) }, enabled = !client.loggingIn) { Text(if (client.loggingIn) "Connecting…" else "Connect TONE3000") }
                        client.authError?.let { Text(it, color = Color(0xFFFF3B30), fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp)) }
                    }
                    detail != null -> { BackHandler { detail = null }; ToneDetail(detail!!, arch, client, target, onDone = { file, name ->
                        client.library = client.library + detail!!.id; library = client.library
                        onDownloaded(file, name, detail!!.gear, detail!!.thumb); onDismiss()
                    }) }
                    else -> {
                        ScrollableTabRow(tab, edgePadding = 8.dp) { tabs.forEachIndexed { i, t -> Tab(tab == i, { tab = i }, text = { Text(t) }) } }
                        OutlinedTextField(query, { query = it; if (tab != 0) tab = 0 }, Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
                            placeholder = { Text("Search captures, makes, creators") }, singleLine = true, leadingIcon = { Icon(Icons.Filled.Search, null) })
                        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            FilterMenu(gears.firstOrNull { it.second == gear }?.first ?: "Gear", gears) { gear = it }
                            if (!isCab) FilterMenu("Arch: ${archs.firstOrNull { it.second == arch }?.first ?: "Any"}", archs) { arch = it }
                            if (tab == 0) {
                                FilterMenu(sorts.firstOrNull { it.second == sort }?.first ?: "Sort", sorts) { sort = it }
                                FilterChip(calibrated, { calibrated = !calibrated }, { Text("Calibrated") })
                                FilterChip(verified, { verified = !verified }, { Text("Verified") })
                            }
                        }
                        Box(Modifier.fillMaxSize()) {
                            LazyColumn(Modifier.fillMaxSize()) {
                                items(tones, key = { it.id }) { t ->
                                    ToneRow(t, t.id in library) { detail = t }
                                    LaunchedEffect(t.id) {
                                        if (t.id == tones.lastOrNull()?.id && page < totalPages && !loading) {
                                            runCatching { fetch(page + 1) }.onSuccess { r ->
                                                val ex = tones.map { it.id }.toSet(); val fresh = r.tones.filter { it.id !in ex }
                                                tones.addAll(fresh); page++; totalPages = if (fresh.isEmpty()) page else r.totalPages
                                            }
                                        }
                                    }
                                    HorizontalDivider()
                                }
                            }
                            if (loading) CircularProgressIndicator(Modifier.align(Alignment.Center))
                            if (!loading && tones.isEmpty()) Text(status.ifEmpty { "No captures. Try another search or filter." }, color = Color.Gray, modifier = Modifier.align(Alignment.Center).padding(24.dp))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FilterMenu(title: String, options: List<Pair<String, String>>, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        AssistChip({ open = true }, { Text(title) }, trailingIcon = { Icon(Icons.Filled.ArrowDropDown, null) })
        DropdownMenu(open, { open = false }) { options.forEach { (l, v) -> DropdownMenuItem({ Text(l) }, { open = false; onPick(v) }) } }
    }
}

@Composable
private fun ToneRow(t: T3KTone, inLibrary: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        AsyncImage(t.thumb, null, Modifier.size(56.dp).clip(RoundedCornerShape(9.dp)).background(Color.Gray.copy(alpha = 0.2f)), contentScale = ContentScale.Crop)
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(t.title, fontWeight = FontWeight.SemiBold, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                if (t.verified) Icon(Icons.Filled.Verified, "Verified", Modifier.size(14.dp).padding(start = 4.dp), tint = Color(0xFF0A84FF))
                if (t.calibrated) Icon(Icons.Filled.Speed, "Calibrated", Modifier.size(14.dp).padding(start = 4.dp), tint = Color(0xFFFF9500))
            }
            if (t.makes.isNotEmpty()) Text(t.makes, fontSize = 12.sp, color = Color.Gray, maxLines = 1)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                t.gear?.let { Text(it.uppercase(), fontSize = 9.sp, fontWeight = FontWeight.Black, modifier = Modifier.clip(CircleShape).background(Color.Gray.copy(alpha = 0.2f)).padding(horizontal = 5.dp)) }
                t.user?.let { Text("@$it", fontSize = 11.sp, color = Color.Gray) }
                t.downloads?.let { Text("↓$it", fontSize = 11.sp, color = Color.Gray) }
                t.favorites?.let { Text("♥$it", fontSize = 11.sp, color = if (t.isFav) Color(0xFFFF2D55) else Color.Gray) }
            }
        }
        if (inLibrary) Icon(Icons.Filled.CheckCircle, "In library", tint = Color(0xFF34C759))
    }
}

@Composable
private fun ToneDetail(tone: T3KTone, arch: String, client: T3KClient, target: String, onDone: (File, String) -> Unit) {
    val scope = rememberCoroutineScope()
    val models = remember { mutableStateListOf<T3KModel>() }
    var loadingModels by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf<Int?>(null) }
    var progress by remember { mutableFloatStateOf(0f) }
    var error by remember { mutableStateOf<String?>(null) }
    var fav by remember { mutableStateOf(tone.isFav) }
    var favCount by remember { mutableIntStateOf(tone.favorites ?: 0) }
    LaunchedEffect(tone.id) { runCatching { client.models(tone.id, arch) }.onSuccess { models.addAll(it) }.onFailure { error = it.message }; loadingModels = false }
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            tone.thumb?.let { AsyncImage(it, null, Modifier.fillMaxWidth().heightIn(max = 220.dp).clip(RoundedCornerShape(12.dp)), contentScale = ContentScale.Fit) }
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp)) {
                Column(Modifier.weight(1f)) {
                    if (tone.makes.isNotEmpty()) Text(tone.makes, fontWeight = FontWeight.SemiBold)
                    tone.user?.let { Text("@$it", fontSize = 12.sp, color = Color.Gray) }
                    if (tone.tags.isNotEmpty()) Text(tone.tags, fontSize = 11.sp, color = Color.Gray, maxLines = 2)
                }
                OutlinedButton({ scope.launch { if (client.setFavorite(tone.id, !fav)) { fav = !fav; favCount += if (fav) 1 else -1 } } }) {
                    Icon(if (fav) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, null, tint = if (fav) Color(0xFFFF2D55) else Color.Gray); Text(" $favCount")
                }
            }
            tone.description?.let { Text(it, fontSize = 14.sp, modifier = Modifier.padding(vertical = 8.dp)) }
            Text(if (target == "cab") "IMPULSE RESPONSES" else "MODELS", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Color.Gray, modifier = Modifier.padding(top = 8.dp))
            if (loadingModels) CircularProgressIndicator(Modifier.padding(16.dp))
            else if (models.isEmpty()) Text("No files for this architecture — try Arch: Any.", fontSize = 12.sp, color = Color.Gray)
        }
        items(models, key = { it.id }) { m ->
            Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(m.name, maxLines = 2)
                    Text(listOfNotNull(m.size, m.arch?.let { "A$it" }).joinToString(" · "), fontSize = 11.sp, color = Color.Gray)
                }
                if (busy == m.id) CircularProgressIndicator({ progress }, Modifier.size(26.dp))
                else IconButton({
                    busy = m.id; progress = 0f; error = null
                    scope.launch {
                        runCatching { client.download(m) { progress = it } }
                            .onSuccess { f -> val ext = f.extension; onDone(f, m.name.replace('/', '-').let { if (it.endsWith(".$ext", true)) it else "$it.$ext" }) }
                            .onFailure { error = it.message }
                        busy = null
                    }
                }, enabled = busy == null) { Icon(Icons.Filled.Download, "Download ${m.name}", tint = MaterialTheme.colorScheme.primary) }
            }
        }
        item { error?.let { Text(it, color = Color(0xFFFF3B30), fontSize = 12.sp) }; Spacer(Modifier.height(24.dp)) }
    }
}
