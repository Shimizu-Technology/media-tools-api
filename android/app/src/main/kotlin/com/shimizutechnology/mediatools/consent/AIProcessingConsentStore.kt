package com.shimizutechnology.mediatools.consent

import android.content.Context
import java.security.MessageDigest

interface ConsentPreferences {
    fun getBoolean(key: String): Boolean
    fun putBoolean(key: String, value: Boolean)
    fun remove(key: String)
}

class AndroidConsentPreferences(context: Context) : ConsentPreferences {
    private val preferences = context.getSharedPreferences("ai_processing_consent", Context.MODE_PRIVATE)

    override fun getBoolean(key: String): Boolean = preferences.getBoolean(key, false)
    override fun putBoolean(key: String, value: Boolean) = preferences.edit().putBoolean(key, value).apply()
    override fun remove(key: String) = preferences.edit().remove(key).apply()
}

/**
 * Stores explicit AI permission per Clerk user on this installation. The raw user ID is never
 * written to preferences, and a versioned key lets a material disclosure change require consent
 * again without weakening older releases.
 */
class AIProcessingConsentStore(private val preferences: ConsentPreferences) {
    fun hasConsent(ownerId: String?): Boolean = ownerId?.let { preferences.getBoolean(key(it)) } ?: false

    fun allow(ownerId: String) = preferences.putBoolean(key(ownerId), true)

    fun revoke(ownerId: String) = preferences.remove(key(ownerId))

    internal fun key(ownerId: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(ownerId.toByteArray(Charsets.UTF_8))
        return "ai_processing_consent:v1:" + digest.joinToString("") { byte -> "%02x".format(byte) }
    }
}
