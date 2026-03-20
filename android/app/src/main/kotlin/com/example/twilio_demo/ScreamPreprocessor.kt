package com.example.twilio_demo

import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

class ScreamPreprocessor {
    companion object {
        const val SAMPLE_RATE = 16000
        const val WINDOW_SECONDS = 2
        const val WINDOW_SAMPLES = SAMPLE_RATE * WINDOW_SECONDS
        const val N_FFT = 512
        const val HOP = 160
        const val N_MELS = 64
        const val FFT_BINS = (N_FFT / 2) + 1
        const val FRAMES = ((WINDOW_SAMPLES - N_FFT) / HOP) + 1
        private const val F_MIN = 60.0
        private const val F_MAX = 7800.0
        private const val EPS = 1e-6
    }

    private val hann = FloatArray(N_FFT) { i ->
        (0.5 - 0.5 * cos(2.0 * Math.PI * i / (N_FFT - 1))).toFloat()
    }
    private val melFilterBank = buildMelFilterBank()
    private val frameBuffer = FloatArray(N_FFT)
    private val real = DoubleArray(N_FFT)
    private val imag = DoubleArray(N_FFT)
    private val mag = FloatArray(FFT_BINS)

    fun computeLogMel(wav: FloatArray, out: FloatArray) {
        for (frame in 0 until FRAMES) {
            val start = frame * HOP
            for (i in 0 until N_FFT) {
                frameBuffer[i] = wav[start + i] * hann[i]
                real[i] = frameBuffer[i].toDouble()
                imag[i] = 0.0
            }

            fft(real, imag)

            for (k in 0 until FFT_BINS) {
                mag[k] = sqrt(real[k] * real[k] + imag[k] * imag[k]).toFloat()
            }

            for (m in 0 until N_MELS) {
                var energy = 0.0
                val filter = melFilterBank[m]
                for (k in 0 until FFT_BINS) {
                    energy += mag[k] * filter[k]
                }
                out[frame * N_MELS + m] = ln(energy + EPS).toFloat()
            }
        }
    }

    private fun fft(real: DoubleArray, imag: DoubleArray) {
        val n = real.size
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j and bit != 0) {
                j = j xor bit
                bit = bit shr 1
            }
            j = j xor bit
            if (i < j) {
                val tmpReal = real[i]
                real[i] = real[j]
                real[j] = tmpReal
                val tmpImag = imag[i]
                imag[i] = imag[j]
                imag[j] = tmpImag
            }
        }

        var len = 2
        while (len <= n) {
            val angle = -2.0 * Math.PI / len
            val wLenCos = cos(angle)
            val wLenSin = sin(angle)
            var start = 0
            while (start < n) {
                var wCos = 1.0
                var wSin = 0.0
                for (k in 0 until len / 2) {
                    val uReal = real[start + k]
                    val uImag = imag[start + k]
                    val idx = start + k + len / 2
                    val vReal = real[idx] * wCos - imag[idx] * wSin
                    val vImag = real[idx] * wSin + imag[idx] * wCos

                    real[start + k] = uReal + vReal
                    imag[start + k] = uImag + vImag
                    real[idx] = uReal - vReal
                    imag[idx] = uImag - vImag

                    val nextWCos = wCos * wLenCos - wSin * wLenSin
                    wSin = wCos * wLenSin + wSin * wLenCos
                    wCos = nextWCos
                }
                start += len
            }
            len = len shl 1
        }
    }

    private fun hzToMel(hz: Double): Double = 2595.0 * (ln(1.0 + hz / 700.0) / ln(10.0))

    private fun melToHz(mel: Double): Double = 700.0 * (10.0.pow(mel / 2595.0) - 1.0)

    private fun buildMelFilterBank(): Array<FloatArray> {
        val melMin = hzToMel(F_MIN)
        val melMax = hzToMel(F_MAX)
        val melPoints = DoubleArray(N_MELS + 2) { i ->
            melMin + (melMax - melMin) * i / (N_MELS + 1)
        }
        val hzPoints = melPoints.map { melToHz(it) }
        val binPoints = hzPoints.map { hz ->
            (((N_FFT * hz) / SAMPLE_RATE).toInt()).coerceIn(0, FFT_BINS - 1)
        }

        return Array(N_MELS) { m ->
            val filter = FloatArray(FFT_BINS)
            val left = binPoints[m]
            val center = binPoints[m + 1]
            val right = binPoints[m + 2]
            if (center != left && right != center) {
                for (k in left until center) {
                    filter[k] = ((k - left).toDouble() / (center - left)).toFloat()
                }
                for (k in center until right) {
                    filter[k] = ((right - k).toDouble() / (right - center)).toFloat()
                }
            }
            filter
        }
    }
}
