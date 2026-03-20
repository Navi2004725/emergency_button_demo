package com.example.twilio_demo

import android.app.Activity
import android.app.Application
import android.os.Bundle

object AppVisibilityTracker : Application.ActivityLifecycleCallbacks {
    @Volatile
    var isAppInForeground: Boolean = false
        private set

    private var resumedActivities = 0
    private var installed = false

    @Synchronized
    fun install(application: Application) {
        if (installed) return
        application.registerActivityLifecycleCallbacks(this)
        installed = true
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit

    override fun onActivityStarted(activity: Activity) = Unit

    override fun onActivityResumed(activity: Activity) {
        resumedActivities += 1
        isAppInForeground = resumedActivities > 0
    }

    override fun onActivityPaused(activity: Activity) {
        resumedActivities = (resumedActivities - 1).coerceAtLeast(0)
        isAppInForeground = resumedActivities > 0
    }

    override fun onActivityStopped(activity: Activity) = Unit

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

    override fun onActivityDestroyed(activity: Activity) = Unit
}
