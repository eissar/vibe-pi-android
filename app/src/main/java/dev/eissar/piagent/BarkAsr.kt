package dev.eissar.piagent

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import java.io.File
import java.nio.FloatBuffer
import java.nio.LongBuffer
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Underdog Bark 3.0 dictation (ASR) running on-device via ONNX Runtime.
 *
 * Model artifacts (exact fp32 weights, no requantization — see
 * bark-android/port/README.md) are NOT embedded in the APK. On first use they
 * are downloaded over HTTP (LAN/Tailscale) into filesDir/bark, which is
 * durable across launches.
 */
class BarkAsr(private val context: Context) {
    companion object {
        private const val BLANK = 8192
        private const val MAX_TOKENS = 4096

        /** Base URL hosting the ONNX files + MANIFEST.txt (serve bark-android/port/onnx). */
        const val MODEL_URL = "http://100.96.187.68:8000/bark"

        @Volatile private var instance: BarkAsr? = null
        fun get(context: Context): BarkAsr =
            instance ?: synchronized(this) { instance ?: BarkAsr(context.applicationContext).also { instance = it } }
    }

    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private val encoder: OrtSession
    private val predict: OrtSession
    private val joint: OrtSession
    private val tokens: List<String>

    init {
        val dir = ensureModels()
        val so = OrtSession.SessionOptions().apply { setIntraOpNumThreads(4) }
        encoder = env.createSession(dir.resolve("encoder.onnx").absolutePath, so)
        predict = env.createSession(dir.resolve("predict.onnx").absolutePath, so)
        joint = env.createSession(dir.resolve("joint.onnx").absolutePath, so)
        tokens = dir.resolve("tokens.txt").readLines().map { it.substringBeforeLast(" ") }
    }

    private fun client() = OkHttpClient.Builder()
        .connectTimeout(java.time.Duration.ofSeconds(10))
        .readTimeout(java.time.Duration.ofMinutes(30))
        .build()

    private fun ensureModels(): File {
        val dir = File(context.filesDir, "bark")
        if (dir.resolve("encoder.onnx").isFile && dir.resolve("tokens.txt").isFile) return dir
        dir.mkdirs()
        val http = client()
        // manifest lists every file; download each into place
        val names = http.newCall(Request.Builder().url("$MODEL_URL/MANIFEST.txt").build()).execute().use { resp ->
            check(resp.isSuccessful) { "model manifest: HTTP ${resp.code}" }
            resp.body!!.string().lines().map { it.trim() }.filter { it.isNotEmpty() }
        }
        names.forEachIndexed { idx, name ->
            val out = File(dir, name)
            if (out.isFile && out.length() > 0) return@forEachIndexed
            val tmp = File(dir, "$name.tmp")
            http.newCall(Request.Builder().url("$MODEL_URL/$name").build()).execute().use { resp ->
                check(resp.isSuccessful) { "model download $name: HTTP ${resp.code}" }
                resp.body!!.byteStream().use { input -> tmp.outputStream().use { output -> input.copyTo(output, 1 shl 20) } }
            }
            check(tmp.renameTo(out)) { "rename failed for $name" }
        }
        return dir
    }

    /** Transcribe 16 kHz mono f32 PCM. Blocking; call off the main thread. */
    fun transcribe(samples: FloatArray): String {
        val wave = FloatArray(samples.size + BarkFrontend.PAD_SAMPLES) { i ->
            if (i < BarkFrontend.PAD_SAMPLES) 0f else samples[i - BarkFrontend.PAD_SAMPLES]
        }
        val feats = BarkFrontend.extract(wave)
        val T = feats.size
        val flat = FloatArray(T * BarkFrontend.N_MELS)
        for (t in 0 until T) System.arraycopy(feats[t], 0, flat, t * BarkFrontend.N_MELS, BarkFrontend.N_MELS)

        val hidden = encoder.run(null, mapOf(
            "in0" to OnnxTensor.createTensor(env, FloatBuffer.wrap(flat), longArrayOf(1, T.toLong(), 128))
        ))[0].value as Array<Array<FloatArray>> // [1, T', 640]

        val frames = hidden[0]
        var h = FloatArray(2 * 640)
        var c = FloatArray(2 * 640)
        var predOut: FloatArray? = null
        var last = BLANK
        val emitted = ArrayList<Int>()
        var t = 0
        while (t < frames.size && emitted.size < MAX_TOKENS) {
            if (predOut == null || last != BLANK) {
                val out = stepPredict(last, h, c)
                predOut = out.first; h = out.second; c = out.third
            }
            val p = predOut!!
            val tl = joint.run(null, mapOf(
                "in0" to OnnxTensor.createTensor(env, FloatBuffer.wrap(p), longArrayOf(1, 640)),
                "in1" to OnnxTensor.createTensor(env, FloatBuffer.wrap(frames[t]), longArrayOf(1, 640)),
            ))
            @Suppress("UNCHECKED_CAST")
            val tokenLogits = (tl[0].value as Array<FloatArray>)[0]
            @Suppress("UNCHECKED_CAST")
            val durLogits = (tl[1].value as Array<FloatArray>)[0]
            tl.close()

            var tok = 0
            for (i in 1 until tokenLogits.size) if (tokenLogits[i] > tokenLogits[tok]) tok = i
            var dur = 0
            for (i in 1 until durLogits.size) if (durLogits[i] > durLogits[dur]) dur = i
            if (tok == BLANK && dur == 0) dur = 1
            if (tok != BLANK) emitted.add(tok)
            last = tok
            t += dur
        }
        return emitted.mapNotNull { id -> tokens.getOrNull(id)?.takeUnless { it == "<blk>" || it == "<unk>" } }
            .joinToString(" ").replace(" ,", ",").replace(" .", ".").replace(" '", "'").trim()
    }

    /** One prediction-net step; returns (projection, newH, newC). */
    private fun stepPredict(last: Int, h: FloatArray, c: FloatArray): Triple<FloatArray, FloatArray, FloatArray> {
        val outs = predict.run(null, mapOf(
            "in0" to OnnxTensor.createTensor(env, LongBuffer.wrap(longArrayOf(last.toLong())), longArrayOf(1)),
            "in1" to OnnxTensor.createTensor(env, FloatBuffer.wrap(h), longArrayOf(2, 1, 640)),
            "in2" to OnnxTensor.createTensor(env, FloatBuffer.wrap(c), longArrayOf(2, 1, 640)),
        ))
        @Suppress("UNCHECKED_CAST")
        val proj = (outs[0].value as Array<FloatArray>)[0]
        val nh = FloatArray(2 * 640) { i -> (outs[1].value as Array<Array<FloatArray>>)[i / 640][0][i % 640] }
        val nc = FloatArray(2 * 640) { i -> (outs[2].value as Array<Array<FloatArray>>)[i / 640][0][i % 640] }
        outs.close()
        return Triple(proj, nh, nc)
    }
}
