package com.shimizutechnology.mediatools.api

import java.security.SecureRandom
import java.time.Instant
import android.util.Base64
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Opaque credentials returned by Media Tools after a verified Clerk bootstrap. */
@Serializable
data class DeviceSessionPair(
    @SerialName("session_id") val sessionId: String,
    @SerialName("user_id") val userId: String,
    @SerialName("access_token") val accessToken: String,
    @SerialName("access_expires_at") val accessExpiresAt: String,
    @SerialName("refresh_token") val refreshToken: String,
    @SerialName("inactive_expires_at") val inactiveExpiresAt: String,
)

@Serializable
data class StoredDeviceSession(
    val pair: DeviceSessionPair,
    val verifiedClerkId: String,
    // Save this before sending refresh. A lost response can retry the same old/new pair.
    val pendingNextRefreshToken: String? = null,
)

/** Saved before bootstrap so a lost success response can recover the same server session. */
@Serializable
data class PendingDeviceSessionBootstrap(
    val verifiedClerkId: String,
    val nextRefreshToken: String,
    val deviceName: String,
)

interface DeviceSessionStore {
    fun load(): StoredDeviceSession?
    fun save(session: StoredDeviceSession)
    fun loadPendingBootstrap(): PendingDeviceSessionBootstrap?
    fun savePendingBootstrap(pending: PendingDeviceSessionBootstrap)
    fun promoteBootstrap(session: StoredDeviceSession)
    fun clearPendingBootstrap()
    fun clear()
}

data class SessionResponse(val status: Int, val body: String)

interface DeviceSessionTransport {
    suspend fun send(path: String, body: String?, bearer: String? = null, method: String = "POST"): SessionResponse
}

/**
 * Owns one first-party device session. All rotations and account transitions
 * share a mutex, so parallel API calls cannot consume the same refresh token.
 */
class DeviceSessionController(
    private val store: DeviceSessionStore,
    private val transport: DeviceSessionTransport,
    private val now: () -> Instant = Instant::now,
    private val randomRefreshToken: () -> String = ::newRefreshToken,
    private val currentExternalIdentity: () -> String?,
    private val json: Json = Json { ignoreUnknownKeys = true },
) : SessionTokenProvider {
    private val mutex = Mutex()
    @Volatile private var stored: StoredDeviceSession? = store.load()
    @Volatile private var rejected = false
    private val _revision = MutableStateFlow(0)
    val revision: StateFlow<Int> = _revision

    val verifiedMigration: Pair<String, String>?
        get() = stored?.let { it.verifiedClerkId to it.pair.userId }

    fun hasConflictingExternalIdentity(currentClerkId: String?): Boolean =
        currentClerkId != null && stored?.verifiedClerkId?.let { it != currentClerkId } == true

    /** A different Clerk identity never inherits this device's account. */
    fun availableOwnerId(currentClerkId: String?): String? {
        val value = stored ?: return null
        if (rejected || (currentClerkId != null && currentClerkId != value.verifiedClerkId)) return null
        return value.pair.userId
    }

    override fun currentOwnerId(): String? = availableOwnerId(currentExternalIdentity())

    /** This method must receive a token from the same verified Clerk identity. */
    suspend fun bootstrap(verifiedClerkId: String, clerkToken: String, deviceName: String): DeviceSessionPair =
        mutex.withLock {
            require(verifiedClerkId.isNotBlank() && clerkToken.isNotBlank())
            val existing = stored
            if (existing != null && !rejected) {
                if (existing.verifiedClerkId != verifiedClerkId) {
                    throw MediaToolsAPIException(409, "Sign out of the current device account before switching accounts.")
                }
                return@withLock existing.pair
            }
            if (currentExternalIdentity() != verifiedClerkId) {
                throw MediaToolsAPIException(409, "The signed-in account changed. Try again.")
            }
            var pending = store.loadPendingBootstrap()
            if (pending != null && pending.verifiedClerkId != verifiedClerkId) {
                // A different verified Clerk identity must never reuse the old
                // identity's successor credential.
                store.clearPendingBootstrap()
                pending = null
            }
            if (pending == null) {
                pending = PendingDeviceSessionBootstrap(
                    verifiedClerkId = verifiedClerkId,
                    nextRefreshToken = randomRefreshToken(),
                    deviceName = deviceName.trim().take(80),
                )
                store.savePendingBootstrap(pending)
            }
            val response = transport.send(
                "/auth/session/bootstrap",
                json.encodeToString(
                    BootstrapRequest(
                        clientType = "android",
                        deviceName = pending.deviceName,
                        nextRefreshToken = pending.nextRefreshToken,
                    )
                ),
                bearer = clerkToken,
            )
            if (response.status == 400 || response.status == 401) {
                store.clearPendingBootstrap()
            }
            val pair = response.requirePair()
            if (currentExternalIdentity() != verifiedClerkId) {
                throw MediaToolsAPIException(409, "The signed-in account changed. Try again.")
            }
            if (pair.refreshToken != pending.nextRefreshToken) {
                throw MediaToolsAPIException(502, "Media Tools returned an invalid device session.")
            }
            val value = StoredDeviceSession(pair, verifiedClerkId)
            store.promoteBootstrap(value)
            stored = value
            rejected = false
            _revision.value++
            pair
        }

    override suspend fun token(expectedOwnerId: String, forceRefresh: Boolean): String =
        accessToken(expectedOwnerId, forceRefresh, rejectedToken = null)

    override suspend fun refreshAfterRejectedToken(expectedOwnerId: String, rejectedToken: String): String =
        accessToken(expectedOwnerId, forceRefresh = true, rejectedToken = rejectedToken)

    private suspend fun accessToken(expectedOwnerId: String, forceRefresh: Boolean, rejectedToken: String?): String =
        mutex.withLock {
            val value = stored ?: throw MediaToolsAPIException(401, "Sign in to continue.")
            if (rejected || value.pair.userId != expectedOwnerId || currentOwnerId() != expectedOwnerId) {
                throw MediaToolsAPIException(401, "The signed-in account changed. Try again.")
            }
            // Another caller may already have replaced the token rejected by this request.
            if (rejectedToken != null && rejectedToken != value.pair.accessToken) return@withLock value.pair.accessToken
            val expiresSoon = runCatching { Instant.parse(value.pair.accessExpiresAt) <= now().plusSeconds(60) }
                .getOrDefault(true)
            if (!forceRefresh && !expiresSoon && value.pendingNextRefreshToken == null) {
                return@withLock value.pair.accessToken
            }
            refreshLocked(value).accessToken
        }

    private suspend fun refreshLocked(value: StoredDeviceSession): DeviceSessionPair {
        val next = value.pendingNextRefreshToken ?: randomRefreshToken().also {
            val pending = value.copy(pendingNextRefreshToken = it)
            store.save(pending)
            stored = pending
        }
        val response = transport.send(
            "/auth/session/refresh",
            json.encodeToString(RefreshRequest(value.pair.refreshToken, next)),
        )
        if (response.status == 401) {
            rejected = true
            _revision.value++
            throw MediaToolsAPIException(401, "Sign in again to continue.")
        }
        val pair = response.requirePair()
        if (pair.userId != value.pair.userId || pair.sessionId != value.pair.sessionId || pair.refreshToken != next) {
            throw MediaToolsAPIException(502, "Media Tools returned an invalid device session.")
        }
        val replacement = value.copy(pair = pair, pendingNextRefreshToken = null)
        store.save(replacement)
        stored = replacement
        _revision.value++
        return pair
    }

    /** Confirm server revocation before deleting the only credential that can revoke it. */
    suspend fun revokeAndClear() = mutex.withLock {
        val value = stored
        // A rejected refresh does not prove the server revoked this session.
        // Keep its credentials until DELETE succeeds, including after rejection.
        if (value != null) {
            val token = if (Instant.parse(value.pair.accessExpiresAt) <= now().plusSeconds(60)) {
                refreshLocked(value).accessToken
            } else {
                value.pair.accessToken
            }
            val response = transport.send("/auth/sessions/${value.pair.sessionId}", null, bearer = token, method = "DELETE")
            if (response.status !in 200..299 && response.status != 404) {
                throw MediaToolsAPIException(response.status, "Could not sign out this device. Check your connection and try again.")
            }
        }
        store.clear()
        stored = null
        rejected = false
        _revision.value++
    }

    /** Account deletion has already revoked server credentials. */
    suspend fun clearAfterDeletion() = mutex.withLock {
        store.clear()
        stored = null
        rejected = false
        _revision.value++
    }

    private fun SessionResponse.requirePair(): DeviceSessionPair {
        if (status !in 200..299) {
            val error = runCatching { json.decodeFromString<APIErrorEnvelope>(body) }.getOrNull()
            throw MediaToolsAPIException(status, error?.message ?: "Device session unavailable ($status).")
        }
        val pair = runCatching { json.decodeFromString<DeviceSessionPair>(body) }.getOrElse {
            throw MediaToolsAPIException(502, "Media Tools returned an unreadable device session.")
        }
        if (pair.userId.isBlank() || pair.sessionId.isBlank() || !pair.accessToken.startsWith("mta_at_") ||
            !pair.refreshToken.startsWith("mta_rt_") ||
            runCatching { Instant.parse(pair.accessExpiresAt); Instant.parse(pair.inactiveExpiresAt) }.isFailure
        ) {
            throw MediaToolsAPIException(502, "Media Tools returned an invalid device session.")
        }
        return pair
    }

    private companion object {
        @Serializable private data class BootstrapRequest(
            @SerialName("client_type") val clientType: String,
            @SerialName("device_name") val deviceName: String,
            @SerialName("next_refresh_token") val nextRefreshToken: String,
        )
        @Serializable private data class RefreshRequest(
            @SerialName("refresh_token") val refreshToken: String,
            @SerialName("next_refresh_token") val nextRefreshToken: String,
        )

        fun newRefreshToken(): String {
            val bytes = ByteArray(32).also(SecureRandom()::nextBytes)
            return "mta_rt_" + Base64.encodeToString(
                bytes,
                Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
            )
        }
    }
}
