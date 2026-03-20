package com.example.twilio_demo

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

data class MonitorStatus(
    val running: Boolean = false,
    val probability: Double = 0.0,
    val danger: Boolean = false,
    val degraded: Boolean = false,
    val stuck: Boolean = false,
    val needsForegroundRestore: Boolean = false,
    val hits90In4s: Int = 0,
    val hits95In2s: Int = 0,
    val hits100In1s: Int = 0,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "running" to running,
        "probability" to probability,
        "danger" to danger,
        "degraded" to degraded,
        "stuck" to stuck,
        "needsForegroundRestore" to needsForegroundRestore,
        "hits90In4s" to hits90In4s,
        "hits95In2s" to hits95In2s,
        "hits100In1s" to hits100In1s,
    )
}

object SafetyMonitorBridge {
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    var latestStatus: MonitorStatus = MonitorStatus()
        private set

    private var eventSink: EventChannel.EventSink? = null

    fun attachSink(sink: EventChannel.EventSink?) {
        eventSink = sink
        sink?.let { publish(latestStatus) }
    }

    fun publish(status: MonitorStatus) {
        latestStatus = status
        val sink = eventSink ?: return
        mainHandler.post {
            sink.success(status.toMap())
        }
    }
}
