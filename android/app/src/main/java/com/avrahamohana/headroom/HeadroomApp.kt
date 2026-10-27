package com.avrahamohana.headroom

import android.app.Application
import com.avrahamohana.headroom.engine.RigEngine
import com.avrahamohana.headroom.midi.MidiController
import com.avrahamohana.headroom.t3k.T3KClient

/** Process-wide singletons: the rig outlives activity recreation (rotation, theme change). */
class HeadroomApp : Application() {
    val rig by lazy { RigEngine(this) }
    val midi by lazy { MidiController(this, rig) }
    val t3k by lazy { T3KClient(this) }
}
