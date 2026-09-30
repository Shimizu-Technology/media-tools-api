package com.shimizutechnology.mediatools.api

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** The only persisted copy of first-party credentials is encrypted with an Android Keystore key. */
class AndroidDeviceSessionStore(context: Context) : DeviceSessionStore {
    private val preferences = context.getSharedPreferences("device_session_v1", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }

    override fun load(): StoredDeviceSession? {
        val encoded = preferences.getString(SESSION_KEY, null) ?: return null
        return runCatching {
            json.decodeFromString<StoredDeviceSession>(decrypt(encoded))
        }.getOrElse {
            // Keystore keys do not survive a restore to a different device.
            // An unreadable credential can never be used to infer account ownership.
            null
        }
    }

    override fun save(session: StoredDeviceSession) {
        check(preferences.edit().putString(SESSION_KEY, encrypt(json.encodeToString(session))).commit()) {
            "Could not save this device's sign-in credentials."
        }
    }

    override fun loadPendingBootstrap(): PendingDeviceSessionBootstrap? {
        val encoded = preferences.getString(PENDING_BOOTSTRAP_KEY, null) ?: return null
        return runCatching {
            json.decodeFromString<PendingDeviceSessionBootstrap>(decrypt(encoded))
        }.getOrNull()
    }

    override fun savePendingBootstrap(pending: PendingDeviceSessionBootstrap) {
        check(
            preferences.edit()
                .putString(PENDING_BOOTSTRAP_KEY, encrypt(json.encodeToString(pending)))
                .commit()
        ) { "Could not save this device's pending sign-in credentials." }
    }

    /** One preferences commit makes session installation and journal removal atomic. */
    override fun promoteBootstrap(session: StoredDeviceSession) {
        check(
            preferences.edit()
                .putString(SESSION_KEY, encrypt(json.encodeToString(session)))
                .remove(PENDING_BOOTSTRAP_KEY)
                .remove(PENDING_RECOVERY_REDEEM_KEY)
                .remove(PENDING_RECOVERY_ROTATION_KEY)
                .commit()
        ) { "Could not save this device's sign-in credentials." }
    }

    override fun clearPendingBootstrap() {
        check(preferences.edit().remove(PENDING_BOOTSTRAP_KEY).commit()) {
            "Could not remove this device's pending sign-in credentials."
        }
    }

    override fun loadPendingRecoveryRedeem(): PendingRecoveryCodeRedeem? =
        loadEncrypted(PENDING_RECOVERY_REDEEM_KEY)

    override fun savePendingRecoveryRedeem(pending: PendingRecoveryCodeRedeem) {
        saveEncrypted(PENDING_RECOVERY_REDEEM_KEY, pending, "Could not save the pending recovery sign-in.")
    }

    override fun clearPendingRecoveryRedeem() {
        remove(PENDING_RECOVERY_REDEEM_KEY, "Could not remove the pending recovery sign-in.")
    }

    override fun loadPendingRecoveryRotation(): PendingRecoveryCodeRotation? =
        loadEncrypted(PENDING_RECOVERY_ROTATION_KEY)

    override fun savePendingRecoveryRotation(pending: PendingRecoveryCodeRotation) {
        saveEncrypted(PENDING_RECOVERY_ROTATION_KEY, pending, "Could not save the pending recovery codes.")
    }

    override fun clearPendingRecoveryRotation() {
        remove(PENDING_RECOVERY_ROTATION_KEY, "Could not remove the pending recovery codes.")
    }

    /** Installs the recovered session and removes its one-time secret in one preferences commit. */
    override fun promoteRecovery(session: StoredDeviceSession) {
        check(
            preferences.edit()
                .putString(SESSION_KEY, encrypt(json.encodeToString(session)))
                .remove(PENDING_BOOTSTRAP_KEY)
                .remove(PENDING_RECOVERY_REDEEM_KEY)
                .remove(PENDING_RECOVERY_ROTATION_KEY)
                .commit()
        ) { "Could not save this device's recovered sign-in." }
    }

    override fun clear() {
        check(
            preferences.edit()
                .remove(SESSION_KEY)
                .remove(PENDING_BOOTSTRAP_KEY)
                .remove(PENDING_RECOVERY_REDEEM_KEY)
                .remove(PENDING_RECOVERY_ROTATION_KEY)
                .commit()
        ) {
            "Could not remove this device's sign-in credentials."
        }
    }

    private inline fun <reified T> loadEncrypted(key: String): T? {
        val encoded = preferences.getString(key, null) ?: return null
        return runCatching { json.decodeFromString<T>(decrypt(encoded)) }.getOrNull()
    }

    private inline fun <reified T> saveEncrypted(key: String, value: T, failure: String) {
        check(preferences.edit().putString(key, encrypt(json.encodeToString(value))).commit()) { failure }
    }

    private fun remove(key: String, failure: String) {
        check(preferences.edit().remove(key).commit()) { failure }
    }

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance(CIPHER)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val encrypted = cipher.doFinal(value.encodeToByteArray())
        return Base64.encodeToString(cipher.iv + encrypted, Base64.NO_WRAP)
    }

    private fun decrypt(encoded: String): String {
        val bytes = Base64.decode(encoded, Base64.NO_WRAP)
        require(bytes.size > IV_SIZE)
        val cipher = Cipher.getInstance(CIPHER)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, bytes.copyOfRange(0, IV_SIZE)))
        return cipher.doFinal(bytes.copyOfRange(IV_SIZE, bytes.size)).decodeToString()
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return generator.generateKey()
    }

    private companion object {
        const val SESSION_KEY = "encrypted_session"
        const val PENDING_BOOTSTRAP_KEY = "encrypted_pending_bootstrap"
        const val PENDING_RECOVERY_REDEEM_KEY = "encrypted_pending_recovery_redeem"
        const val PENDING_RECOVERY_ROTATION_KEY = "encrypted_pending_recovery_rotation"
        const val KEY_ALIAS = "com.shimizu-technology.media-tools.device-session.v1"
        const val CIPHER = "AES/GCM/NoPadding"
        const val IV_SIZE = 12
    }
}
