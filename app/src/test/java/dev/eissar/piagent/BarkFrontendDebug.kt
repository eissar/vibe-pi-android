package dev.eissar.piagent

import org.junit.Test
import java.io.File

class BarkFrontendDebug {
    fun readRef(name: String) = File(javaClass.classLoader.getResource(name)!!.toURI())

    @Test
    fun debugStages() {
        val wave = readRef("ref_wave.f32").readBytes().let { b ->
            FloatArray(b.size / 4) { i -> java.lang.Float.intBitsToFloat(
                ((b[i*4].toInt() and 0xFF)) or ((b[i*4+1].toInt() and 0xFF) shl 8)
                    or ((b[i*4+2].toInt() and 0xFF) shl 16) or ((b[i*4+3].toInt() and 0xFF) shl 24)) }
        }
        val raw = BarkFrontend.extractRaw(wave)
        var min = Float.MAX_VALUE; var max = -Float.MAX_VALUE
        raw.forEach { r -> r.forEach { if (it < min) min = it; if (it > max) max = it } }
        println("raw stats min=$min max=$max")
    }
}
