package com.example.twilio_demo

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val METHOD_CHANNEL = "usafe/monitor"
        private const val EVENT_CHANNEL = "usafe/monitor_events"
        private const val EXTRA_RESTORE_LISTENING = "restore_listening"
    }

    private var pendingRestoreRequest = false

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        AppVisibilityTracker.install(application)
        pendingRestoreRequest = intent?.getBooleanExtra(EXTRA_RESTORE_LISTENING, false) == true
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getBooleanExtra(EXTRA_RESTORE_LISTENING, false)) {
            pendingRestoreRequest = true
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startMonitoring" -> {
                        SafetyMonitorService.startService(this)
                        result.success(true)
                    }
                    "stopMonitoring" -> {
                        SafetyMonitorService.stopService(this)
                        result.success(true)
                    }
                    "restoreListening" -> {
                        SafetyMonitorService.restoreListeningWhenVisible(this)
                        result.success(true)
                    }
                    "consumeRestoreRequest" -> {
                        val shouldRestore = pendingRestoreRequest
                        if (shouldRestore) {
                            android.util.Log.d("MainActivity", "Notification restore request consumed")
                        }
                        pendingRestoreRequest = false
                        result.success(shouldRestore)
                    }
                    "getStatus" -> result.success(SafetyMonitorBridge.latestStatus.toMap())
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    SafetyMonitorBridge.attachSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    SafetyMonitorBridge.attachSink(null)
                }
            })
    }
}
