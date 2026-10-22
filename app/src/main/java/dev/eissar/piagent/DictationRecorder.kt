package dev.eissar.piagent

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.content.Context
import android.media.MediaRecorder

/** Mic capture for on-device Bark dictation: 16 kHz mono PCM. */
class DictationRecorder(
    private val context: Context,
    private val onResult: (String) -> Unit,
    private val onError: (Exception?) -> Unit,
) {
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    @Volatile private var running = false

    @SuppressLint("MissingPermission") // caller requests RECORD_AUDIO first
    fun start() {
        val minBuf = AudioRecord.getMinBufferSize(SR, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        record = AudioRecord(
            MediaRecorder.AudioSource.MIC, SR, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_FLOAT, maxOf(minBuf, SR * 4)
        )
        running = true
        record?.startRecording()
        thread = Thread {
            val collected = ArrayList<Float>(SR * 60)
            val buf = FloatArray(SR / 10) // 100 ms
            try {
                val rec = record!!
                while (running) {
                    val n = rec.read(buf, 0, buf.size, AudioRecord.READ_BLOCKING)
                    if (n > 0) for (i in 0 until n) collected.add(buf[i])
                }
                val samples = FloatArray(collected.size)
                for (i in samples.indices) samples[i] = collected[i]
                val text = BarkAsr.get(context).transcribe(samples)
                if (text.isEmpty()) onError(Exception("nothing heard")) else onResult(text)
            } catch (e: Exception) {
                onError(e)
            } finally {
                try { record?.stop(); record?.release() } catch (_: Exception) {}
                record = null
            }
        }.apply { start() }
    }

    fun stop() {
        running = false
        thread?.join(3000)
        thread = null
    }

    companion object {
        private const val SR = 16000
    }
}
