package com.shimizutechnology.mediatools.api

import java.time.Instant
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Opaque credentials returned by Media Tools after verified native authentication. */
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
    // Id from the retired third-party sign-in, written by earlier internal builds. The
    // JSON name is the persisted one: keeping it means those stored sessions still decode
    // after the update, and their device-local AI consent still migrates.
    @SerialName("verifiedClerkId") val legacyOwnerId: String? = null,
    // Save this before sending refresh. A lost response can retry the same old/new pair.
    val pendingNextRefreshToken: String? = null,
)

/**
 * Saved before password sign-in so a lost success response can recover the same server
 * session. It holds the successor refresh credential, never the password: a retry after a
 * relaunch needs the person to type the password again.
 */
@Serializable
data class PendingPasswordLogin(
    val email: String,
    val nextRefreshToken: String,
    val deviceName: String,
)

@Serializable
data class PendingRecoveryCodeRedeem(
    val code: String,
    val nextRefreshToken: String,
)

@Serializable
data class PendingRecoveryCodeRotation(
    val userId: String,
    val rotationId: String,
    val codes: List<String>,
)

interface DeviceSessionStore {
    fun load(): StoredDeviceSession?
    fun save(session: StoredDeviceSession)
    fun loadPendingPasswordLogin(): PendingPasswordLogin?
    fun savePendingPasswordLogin(pending: PendingPasswordLogin)
    fun clearPendingPasswordLogin()
    fun loadPendingRecoveryRedeem(): PendingRecoveryCodeRedeem?
    fun savePendingRecoveryRedeem(pending: PendingRecoveryCodeRedeem)
    fun clearPendingRecoveryRedeem()
    fun loadPendingRecoveryRotation(): PendingRecoveryCodeRotation?
    fun savePendingRecoveryRotation(pending: PendingRecoveryCodeRotation)
    fun clearPendingRecoveryRotation()
    /** Installs a new session and removes every pending sign-in journal in one durable commit. */
    fun promote(session: StoredDeviceSession)
    fun clear()
}

data class SessionResponse(val status: Int, val body: String, val retryAfterSeconds: Int? = null)

interface DeviceSessionTransport {
    suspend fun send(path: String, body: String?, bearer: String? = null, method: String = "POST"): SessionResponse
}

/**
 * Owns one first-party device session. All rotations and account transitions
 * share a mutex, so parallel API calls cannot consume the same refresh token.
 *
 * Only a refresh the server rejects (401) ends the session. Network errors, timeouts,
 * 429, 5xx, and `session_refresh_in_progress` leave the stored credentials untouched,
 * so the same old/new pair is retried next time.
 */
class DeviceSessionController(
    private val store: DeviceSessionStore,
    private val transport: DeviceSessionTransport,
    private val now: () -> Instant = Instant::now,
    private val randomRefreshToken: () -> String = ::newDeviceRefreshToken,
    private val json: Json = Json { ignoreUnknownKeys = true },
) : SessionTokenProvider {
    private val mutex = Mutex()
    @Volatile private var stored: StoredDeviceSession? = store.load()
    @Volatile private var rejected = false
    private val _revision = MutableStateFlow(0)
    val revision: StateFlow<Int> = _revision

    /** Retired sign-in id and the stable user id, so device-local consent can follow the account. */
    val verifiedMigration: Pair<String, String>?
        get() = stored?.let { value -> value.legacyOwnerId?.let { it to value.pair.userId } }

    /** Null when signed out or after the server rejected a refresh. */
    override fun currentOwnerId(): String? {
        val value = stored ?: return null
        return if (rejected) null else value.pair.userId
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
        val request = json.encodeToString(RefreshRequest(value.pair.refreshToken, next))
        var retries = 0
        var response = transport.send("/auth/session/refresh", request)
        // 409 session_refresh_in_progress means another caller just advanced this session
        // and does not revoke it. Retry the identical request a couple of times; if it keeps
        // happening, surface it as retryable and keep the stored pair.
        while (response.status == 409 && retries < REFRESH_IN_PROGRESS_RETRIES &&
            response.toApiException("Session refresh").errorCode == "session_refresh_in_progress"
        ) {
            delay(REFRESH_RETRY_BASE_MILLIS shl retries)
            retries++
            response = transport.send("/auth/session/refresh", request)
        }
        if (response.status == 401) {
            rejected = true
            _revision.value++
            throw MediaToolsAPIException(401, "Sign in again to continue.", "invalid_session")
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

    /**
     * Installs the result of password or recovery-code sign-in, but only when no other
     * account is active on this device. A session the server already rejected may be replaced.
     */
    suspend fun installSession(pair: DeviceSessionPair, expectedRefreshToken: String) = mutex.withLock {
        if (stored != null && !rejected) {
            throw MediaToolsAPIException(409, "Sign out of the current account before signing in again.")
        }
        if (pair.refreshToken != expectedRefreshToken) {
            throw MediaToolsAPIException(502, "Media Tools returned an invalid device session.")
        }
        validatePair(pair)
        val value = StoredDeviceSession(pair = pair)
        store.promote(value)
        stored = value
        rejected = false
        _revision.value++
    }

    private fun SessionResponse.requirePair(): DeviceSessionPair {
        if (status !in 200..299) throw toApiException("Device session unavailable", json)
        val pair = runCatching { json.decodeFromString<DeviceSessionPair>(body) }.getOrElse {
            throw MediaToolsAPIException(502, "Media Tools returned an unreadable device session.")
        }
        validatePair(pair)
        return pair
    }

    private fun validatePair(pair: DeviceSessionPair) {
        if (pair.userId.isBlank() || pair.sessionId.isBlank() || !pair.accessToken.startsWith("mta_at_") ||
            !pair.refreshToken.startsWith("mta_rt_") ||
            runCatching { Instant.parse(pair.accessExpiresAt); Instant.parse(pair.inactiveExpiresAt) }.isFailure
        ) throw MediaToolsAPIException(502, "Media Tools returned an invalid device session.")
    }

    private companion object {
        const val REFRESH_IN_PROGRESS_RETRIES = 2
        const val REFRESH_RETRY_BASE_MILLIS = 500L

        @Serializable private data class RefreshRequest(
            @SerialName("refresh_token") val refreshToken: String,
            @SerialName("next_refresh_token") val nextRefreshToken: String,
        )
    }
}
