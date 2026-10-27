package com.avrahamohana.headroom

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.lifecycleScope
import com.avrahamohana.headroom.engine.RigEngine
import com.avrahamohana.headroom.midi.MidiController
import com.avrahamohana.headroom.t3k.T3KClient
import com.avrahamohana.headroom.ui.HeadroomTheme
import com.avrahamohana.headroom.ui.MainScreen
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val app get() = application as HeadroomApp
    private val micPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) app.rig.start() else app.rig.lastError = "Microphone access denied. Enable it in Settings → Apps → Headroom → Permissions."
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { HeadroomTheme(app.rig.appearance) { MainScreen(app.rig, app.midi, app.t3k) } }
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); handleIntent(intent) }

    private fun handleIntent(i: Intent?) {
        val data = i?.data ?: return
        if (data.scheme == "namrig") lifecycleScope.launch { app.t3k.handleRedirect(data) }
    }

    override fun onStart() {
        super.onStart()
        app.midi.start()
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) app.rig.start()
        else micPermission.launch(Manifest.permission.RECORD_AUDIO)
    }

    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations) { app.rig.stop(); app.midi.stop() }
    }
}
