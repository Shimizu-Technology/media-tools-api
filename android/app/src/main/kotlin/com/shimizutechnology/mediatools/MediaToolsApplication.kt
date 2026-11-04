package com.shimizutechnology.mediatools

import android.app.Application

class MediaToolsApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // The retired third-party sign-in SDK kept its session cache in this file. Nothing
        // reads it now, so remove it rather than leave an old credential on the device.
        deleteSharedPreferences("clerk_preferences")
    }
}
