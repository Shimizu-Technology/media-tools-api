package com.shimizutechnology.mediatools

import android.app.Application
import com.clerk.api.Clerk
import com.clerk.api.ClerkConfigurationOptions

class MediaToolsApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        if (isClerkConfigured(BuildConfig.CLERK_PUBLISHABLE_KEY)) {
            Clerk.initialize(
                this,
                BuildConfig.CLERK_PUBLISHABLE_KEY,
                ClerkConfigurationOptions(telemetryEnabled = false),
            )
        }
    }

    companion object {
        fun isClerkConfigured(value: String): Boolean =
            (value.startsWith("pk_test_") || value.startsWith("pk_live_")) &&
                value != "pk_test_placeholder_for_ci"
    }
}
