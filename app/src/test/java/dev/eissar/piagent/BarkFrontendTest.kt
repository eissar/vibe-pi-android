package dev.eissar.piagent

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.nio.file.Paths

/** Validates BarkFrontend against features dumped from HF ParakeetFeatureExtractor. */
class BarkFrontendTest {
    private fun res(name: String): File {
        // works both from Gradle (resources on classpath) and IDE
        val url = javaClass.classLoader?.getResource(name)
            ?: throw AssertionError("missing test resource $name")
        return File(url.toURI())
    }

    @Test
    fun matchesReferenceFeatures() {
        val wave = res("ref_wave.f32").readBytes().let { bytes ->
            FloatArray(bytes.size / 4) { i ->
                java.lang.Float.intBitsToFloat(
                    ((bytes[i * 4].toInt() and 0xFF)) or ((bytes[i * 4 + 1].toInt() and 0xFF) shl 8)
                        or ((bytes[i * 4 + 2].toInt() and 0xFF) shl 16) or ((bytes[i * 4 + 3].toInt() and 0xFF) shl 24)
                )
            }
        }
        val ref = res("ref_feats.f32").readBytes().let { bytes ->
            FloatArray(bytes.size / 4) { i ->
                java.lang.Float.intBitsToFloat(
                    ((bytes[i * 4].toInt() and 0xFF)) or ((bytes[i * 4 + 1].toInt() and 0xFF) shl 8)
                        or ((bytes[i * 4 + 2].toInt() and 0xFF) shl 16) or ((bytes[i * 4 + 3].toInt() and 0xFF) shl 24)
                )
            }
        }
        val feats = BarkFrontend.extract(wave)
        val refFrames = ref.size / BarkFrontend.N_MELS
        assertEquals(refFrames, feats.size)

        var maxDiff = 0f
        var sumSq = 0.0
        var sumSqRef = 0.0
        for (t in 0 until refFrames) for (m in 0 until BarkFrontend.N_MELS) {
            val d = Math.abs(feats[t][m] - ref[t * BarkFrontend.N_MELS + m])
            if (d > maxDiff) maxDiff = d
            sumSq += d.toDouble() * d
            sumSqRef += ref[t * BarkFrontend.N_MELS + m].toDouble() * ref[t * BarkFrontend.N_MELS + m]
        }
        val relRms = Math.sqrt(sumSq / sumSqRef)
        println("maxDiff=$maxDiff relRms=$relRms")
        // encoder was verified insensitive at ~2e-6; allow small numerical slack
        assert(maxDiff < 0.05f) { "maxDiff=$maxDiff" }
        assert(relRms < 0.01) { "relRms=$relRms" }
    }
}
