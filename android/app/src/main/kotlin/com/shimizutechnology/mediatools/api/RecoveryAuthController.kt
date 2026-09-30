package com.shimizutechnology.mediatools.api

import android.util.Base64
import java.security.SecureRandom
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
data class RecoveryCodeStatus(val remaining: Int)

/**
 * Owns native recovery-code sign-in and replacement. Every secret-bearing
 * retry journal uses the same Android Keystore protected store as the device
 * session, and account-scoped codes are checked against the stable users.id.
 */
class RecoveryAuthController(
    private val store: DeviceSessionStore,
    private val transport: DeviceSessionTransport,
    private val deviceSession: DeviceSessionController,
    private val deviceName: () -> String,
    private val randomRefreshToken: () -> String = ::newDeviceRefreshToken,
    private val json: Json = Json { ignoreUnknownKeys = true },
) {
    private val mutex = Mutex()

    suspend fun redeem(code: String): DeviceSessionPair = mutex.withLock {
        if (deviceSession.currentOwnerId() != null) {
            throw MediaToolsAPIException(409, "Sign out of the current account before using a recovery code.")
        }
        // Match the server's accepted representation so adding or removing
        // display hyphens cannot strand an otherwise exact retry journal.
        val normalized = code.trim().uppercase().replace("-", "")
        if (normalized.isBlank()) throw MediaToolsAPIException(400, "Enter a recovery code.")

        var pending = store.loadPendingRecoveryRedeem()
        if (pending != null && pending.code != normalized) {
            throw MediaToolsAPIException(409, "Retry the recovery code already in progress before using a different code.")
        }
        if (pending == null) {
            pending = PendingRecoveryCodeRedeem(normalized, randomRefreshToken())
            store.savePendingRecoveryRedeem(pending)
        }

        val response = transport.send(
            path = "/auth/recovery/redeem",
            body = json.encodeToString(
                RecoveryRedeemRequest(
                    code = pending.code,
                    clientType = "android",
                    deviceName = deviceName().trim().take(80),
                    nextRefreshToken = pending.nextRefreshToken,
                )
            ),
        )
        if (response.status == 400 || response.status == 401 || response.status == 404) {
            store.clearPendingRecoveryRedeem()
            throw MediaToolsAPIException(401, "That recovery code did not work. Check the code and try again.")
        }
        val pair = response.requireDecoded<DeviceSessionPair>("Recovery sign-in unavailable")
        if (pair.refreshToken != pending.nextRefreshToken) {
            throw MediaToolsAPIException(502, "Media Tools returned an invalid device session.")
        }
        // The store promotes the session and removes the submitted code in one
        // durable commit. A lost response before this point retries the exact
        // code and successor and recovers the same server session.
        deviceSession.installRecoveredSession(pair, pending.nextRefreshToken)
        pair
    }

    suspend fun status(): RecoveryCodeStatus = mutex.withLock {
        val owner = requireOwner()
        sendAuthenticated(owner, "/auth/recovery", null, "GET")
            .requireDecoded("Could not check recovery codes")
    }

    suspend fun beginRotation(): List<String> = mutex.withLock {
        val owner = requireOwner()
        store.loadPendingRecoveryRotation()?.let { pending ->
            if (pending.userId != owner) {
                store.clearPendingRecoveryRotation()
                throw MediaToolsAPIException(401, "The signed-in account changed. Create recovery codes for this account.")
            }
            return@withLock pending.codes
        }

        val response = sendAuthenticated(owner, "/auth/recovery/rotation/begin", "{}")
            .requireDecoded<RecoveryRotationResponse>("Could not create recovery codes")
        if (response.rotationId.isBlank() || response.codes.size != 10 || response.codes.any(String::isBlank)) {
            throw MediaToolsAPIException(502, "Media Tools returned invalid recovery codes.")
        }
        store.savePendingRecoveryRotation(
            PendingRecoveryCodeRotation(owner, response.rotationId, response.codes)
        )
        response.codes
    }

    suspend fun confirmRotation(): RecoveryCodeStatus = mutex.withLock {
        val owner = requireOwner()
        val pending = store.loadPendingRecoveryRotation()
            ?: throw MediaToolsAPIException(409, "Create and save recovery codes before confirming them.")
        if (pending.userId != owner) {
            store.clearPendingRecoveryRotation()
            throw MediaToolsAPIException(401, "The signed-in account changed. Create recovery codes for this account.")
        }
        val response = sendAuthenticated(
            owner,
            "/auth/recovery/rotation/confirm",
            json.encodeToString(RecoveryRotationConfirmRequest(pending.rotationId)),
        )
        if (response.status == 400 || response.status == 401 || response.status == 404) {
            store.clearPendingRecoveryRotation()
            throw MediaToolsAPIException(
                401,
                "These recovery codes expired or were replaced. Create a new set; your previous active codes are unchanged unless another device replaced them.",
            )
        }
        val status = response.requireDecoded<RecoveryCodeStatus>("Could not confirm recovery codes")
        store.clearPendingRecoveryRotation()
        status
    }

    private fun requireOwner(): String = deviceSession.currentOwnerId()
        ?: throw MediaToolsAPIException(401, "Sign in to manage recovery codes.")

    private suspend fun sendAuthenticated(
        owner: String,
        path: String,
        body: String?,
        method: String = "POST",
    ): SessionResponse {
        val firstToken = deviceSession.token(owner)
        val first = transport.send(path, body, bearer = firstToken, method = method)
        if (first.status != 401) return first
        val replacement = deviceSession.refreshAfterRejectedToken(owner, firstToken)
        return transport.send(path, body, bearer = replacement, method = method)
    }

    private inline fun <reified T> SessionResponse.requireDecoded(action: String): T {
        if (status !in 200..299) {
            val envelope = runCatching { json.decodeFromString<APIErrorEnvelope>(body) }.getOrNull()
            throw MediaToolsAPIException(status, envelope?.message ?: "$action ($status).")
        }
        return runCatching { json.decodeFromString<T>(body) }.getOrElse {
            throw MediaToolsAPIException(502, "Media Tools returned an unreadable response.")
        }
    }

    @Serializable
    private data class RecoveryRedeemRequest(
        val code: String,
        @SerialName("client_type") val clientType: String,
        @SerialName("device_name") val deviceName: String,
        @SerialName("next_refresh_token") val nextRefreshToken: String,
    )

    @Serializable
    private data class RecoveryRotationResponse(
        @SerialName("rotation_id") val rotationId: String,
        val codes: List<String>,
    )

    @Serializable
    private data class RecoveryRotationConfirmRequest(
        @SerialName("rotation_id") val rotationId: String,
    )
}

internal fun newDeviceRefreshToken(): String {
    val bytes = ByteArray(32).also(SecureRandom()::nextBytes)
    return "mta_rt_" + Base64.encodeToString(
        bytes,
        Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
    )
}
