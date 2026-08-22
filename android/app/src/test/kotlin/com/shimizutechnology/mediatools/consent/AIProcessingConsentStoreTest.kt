package com.shimizutechnology.mediatools.consent

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AIProcessingConsentStoreTest {
    @Test
    fun `consent is explicit account scoped and revocable`() {
        val preferences = MemoryPreferences()
        val store = AIProcessingConsentStore(preferences)

        assertFalse(store.hasConsent(null))
        assertFalse(store.hasConsent("user_one"))
        store.allow("user_one")

        assertTrue(store.hasConsent("user_one"))
        assertFalse(store.hasConsent("user_two"))

        store.revoke("user_one")
        assertFalse(store.hasConsent("user_one"))
    }

    @Test
    fun `preference key is versioned and does not expose raw user id`() {
        val store = AIProcessingConsentStore(MemoryPreferences())
        val first = store.key("user_sensitive_identifier")
        val second = store.key("another_user")

        assertTrue(first.startsWith("ai_processing_consent:v1:"))
        assertFalse(first.contains("user_sensitive_identifier"))
        assertNotEquals(first, second)
    }
}

private class MemoryPreferences : ConsentPreferences {
    private val values = mutableMapOf<String, Boolean>()
    override fun getBoolean(key: String): Boolean = values[key] ?: false
    override fun putBoolean(key: String, value: Boolean) { values[key] = value }
    override fun remove(key: String) { values.remove(key) }
}
