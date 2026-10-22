package dev.eissar.piagent

/**
 * Log-mel fbank frontend matching transformers' ParakeetFeatureExtractor
 * (Bark 3.0 / parakeet-tdt-0.6b-v3), pure Kotlin, no Android deps.
 *
 * Pipeline (exact spec):
 *  - 16 kHz mono f32; caller prepends 0.25 s (4000 samples) of silence
 *  - preemphasis 0.97 (first sample kept as-is); padded frames re-zeroed
 *  - STFT: n_fft 512, win 400 (Hann, symmetric), hop 160, center=True with zero pad (256)
 *  - power spectrum |X|^2
 *  - mel: 128 filters, fmin 0, fmax 8000, librosa slaney scale + slaney area norm
 *  - log(mel + 2^-24)
 *  - per-bin mean/std over valid frames (var with N-1 denominator), std + 1e-5
 *  - frames beyond floor(totalSamples/160) are zeroed (mask)
 */
object BarkFrontend {
    const val SR = 16000
    const val N_FFT = 512
    const val WIN = 400
    const val HOP = 160
    const val N_MELS = 128
    const val PAD_SAMPLES = 4000 // 0.25 s lead-in, the evaluated setting
    private val LOG_ZERO_GUARD = Math.pow(2.0, -24.0).toFloat()
    private val LOG_STEP = kotlin.math.ln(6.4) / 27.0 // librosa slaney log step
    private const val EPS = 1e-5f

    private val window = FloatArray(WIN) { n ->
        // torch.hann_window(periodic=false) == symmetric Hann
        (0.5 - 0.5 * kotlin.math.cos(2.0 * Math.PI * n / (WIN - 1))).toFloat()
    }
    val melFilters: Array<FloatArray> = buildMelFilters()

    private fun Double.pow(p: Double) = Math.pow(this, p)
    private fun Int.pow(p: Int) = Math.pow(this.toDouble(), p.toDouble())

    /** Slaney mel scale (librosa htk=false). */
    private fun hzToMel(f: Double): Double {
        val fSp = 200.0 / 3.0
        val minLogHz = 1000.0
        val minLogMel = minLogHz / fSp
        return if (f < minLogHz) f / fSp else minLogMel + kotlin.math.ln(f / minLogHz) / LOG_STEP
    }

    private fun melToHz(m: Double): Double {
        val fSp = 200.0 / 3.0
        val minLogHz = 1000.0
        val minLogMel = minLogHz / fSp
        return if (m < minLogMel) m * fSp else minLogHz * kotlin.math.exp(LOG_STEP * (m - minLogMel))
    }

    fun buildMelFilters(): Array<FloatArray> {
        val nBins = N_FFT / 2 + 1
        val low = hzToMel(0.0)
        val high = hzToMel(SR / 2.0)
        val pts = DoubleArray(N_MELS + 2) { i -> melToHz(low + (high - low) * i / (N_MELS + 1)) }
        val bins = DoubleArray(N_MELS + 2) { i -> pts[i] / (SR.toDouble() / N_FFT) } // fft freqs are k*sr/n_fft
        val filters = Array(N_MELS) { FloatArray(nBins) }
        val hzPerBin = SR.toDouble() / N_FFT
        for (j in 0 until N_MELS) {
            val left = bins[j]; val center = bins[j + 1]; val right = bins[j + 2]
            for (k in 0 until nBins) {
                val w = when {
                    k < left || k > right -> 0.0
                    k <= center -> (k - left) / (center - left)
                    else -> (right - k) / (right - center)
                }
                filters[j][k] = (w * 2.0 / ((right - left) * hzPerBin)).toFloat() // slaney area norm (in Hz)
            }
        }
        return filters
    }

    /** In-place radix-2 FFT. re/im length must be a power of two. */
    private fun fft(re: DoubleArray, im: DoubleArray) {
        val n = re.size
        // bit reversal
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j and bit != 0) { j = j xor bit; bit = bit shr 1 }
            j = j or bit
            if (i < j) { re[i] = re[j].also { re[j] = re[i] }; im[i] = im[j].also { im[j] = im[i] } }
        }
        var len = 2
        while (len <= n) {
            val ang = -2.0 * Math.PI / len
            val wr = kotlin.math.cos(ang); val wi = kotlin.math.sin(ang)
            var i = 0
            while (i < n) {
                var cwr = 1.0; var cwi = 0.0
                for (k in 0 until len / 2) {
                    val ur = re[i + k]; val ui = im[i + k]
                    val vr = re[i + k + len / 2] * cwr - im[i + k + len / 2] * cwi
                    val vi = re[i + k + len / 2] * cwi + im[i + k + len / 2] * cwr
                    re[i + k] = ur + vr; im[i + k] = ui + vi
                    re[i + k + len / 2] = ur - vr; im[i + k + len / 2] = ui - vi
                    val nwr = cwr * wr - cwi * wi; cwi = cwr * wi + cwi * wr; cwr = nwr
                }
                i += len
            }
            len = len shl 1
        }
    }

    /** Debug: power spectrum of frame t of a (pre-padded, pre-emphasized) wave. */
    fun framePower(wave: FloatArray, t: Int): FloatArray {
        val nBins = N_FFT / 2 + 1
        val re = DoubleArray(N_FFT); val im = DoubleArray(N_FFT)
        val off = t * HOP - N_FFT / 2
        for (k in 0 until WIN) {
            val idx = off + k
            val v = if (idx in wave.indices) wave[idx] else 0f
            re[k] = (v * window[k]).toDouble()
        }
        fft(re, im)
        return FloatArray(nBins) { k -> (re[k] * re[k] + im[k] * im[k]).toFloat() }
    }

    /** waveform -> raw log-mel [nFrames][128] before normalization. */
    fun extractRaw(wave: FloatArray): Array<FloatArray> {
        val n = wave.size
        val numFrames = 1 + n / HOP
        val validFrames = n / HOP // floor((len + n_fft - n_fft)/hop), len includes lead-in
        val nBins = N_FFT / 2 + 1

        // preemphasis, then re-zero the lead-in region so it stays silence
        val x = FloatArray(n)
        x[0] = wave[0]
        for (i in 1 until n) x[i] = wave[i] - 0.97f * wave[i - 1]
        for (i in 0 until PAD_SAMPLES) x[i] = 0f

        val feats = Array(numFrames) { FloatArray(N_MELS) }
        val re = DoubleArray(N_FFT)
        val im = DoubleArray(N_FFT)
        for (t in 0 until numFrames) {
            // torch.stft pads the 400-pt window with 56 zeros each side inside the 512 frame,
        // so the window is centered on sample t*HOP (not on the frame start).
        val off = t * HOP - WIN / 2
            java.util.Arrays.fill(re, 0.0); java.util.Arrays.fill(im, 0.0)
            for (k in 0 until WIN) {
                val idx = off + k
                val s = if (idx in 0 until n) x[idx] else 0f
                re[k] = (s * window[k]).toDouble()
            }
            fft(re, im)
            for (k in 0 until nBins) {
                val p = (re[k] * re[k] + im[k] * im[k]).toFloat()
                for (mm in 0 until N_MELS) {
                    val w = melFilters[mm][k]
                    if (w != 0f) feats[t][mm] += w * p
                }
            }
            for (mm in 0 until N_MELS) feats[t][mm] = kotlin.math.ln(feats[t][mm] + LOG_ZERO_GUARD)
        }
        return feats
    }

    fun extract(wave: FloatArray): Array<FloatArray> {
        val feats = extractRaw(wave)
        normalize(feats)
        return feats
    }

    private fun normalize(feats: Array<FloatArray>) {
        // per-bin normalization over valid frames; zero padded frames after
        val numFrames = feats.size
        val validFrames = numFrames - 1 // floor(n/HOP), since numFrames = 1 + floor(n/HOP)
        val mean = FloatArray(N_MELS)
        for (t in 0 until validFrames) for (mm in 0 until N_MELS) mean[mm] += feats[t][mm]
        for (mm in 0 until N_MELS) mean[mm] /= validFrames
        val vari = FloatArray(N_MELS)
        for (t in 0 until validFrames) for (mm in 0 until N_MELS) {
            val d = feats[t][mm] - mean[mm]; vari[mm] += d * d
        }
        for (mm in 0 until N_MELS) vari[mm] /= (validFrames - 1).coerceAtLeast(1)
        for (t in 0 until numFrames) for (mm in 0 until N_MELS) {
            feats[t][mm] = if (t < validFrames) {
                (feats[t][mm] - mean[mm]) / (kotlin.math.sqrt(vari[mm]) + EPS)
            } else 0f
        }
    }
}
