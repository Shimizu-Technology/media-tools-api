package com.shimizutechnology.mediatools.api

/** In-memory stand-in for the Keystore-backed store. Mirrors its "one commit" promote and clear. */
class FakeSessionStore(
    var value: StoredDeviceSession? = null,
    var pendingLogin: PendingPasswordLogin? = null,
    var pendingRedeem: PendingRecoveryCodeRedeem? = null,
    var pendingRotation: PendingRecoveryCodeRotation? = null,
) : DeviceSessionStore {
    override fun load() = value
    override fun save(session: StoredDeviceSession) { value = session }
    override fun loadPendingPasswordLogin() = pendingLogin
    override fun savePendingPasswordLogin(pending: PendingPasswordLogin) { pendingLogin = pending }
    override fun clearPendingPasswordLogin() { pendingLogin = null }
    override fun loadPendingRecoveryRedeem() = pendingRedeem
    override fun savePendingRecoveryRedeem(pending: PendingRecoveryCodeRedeem) { pendingRedeem = pending }
    override fun clearPendingRecoveryRedeem() { pendingRedeem = null }
    override fun loadPendingRecoveryRotation() = pendingRotation
    override fun savePendingRecoveryRotation(pending: PendingRecoveryCodeRotation) { pendingRotation = pending }
    override fun clearPendingRecoveryRotation() { pendingRotation = null }
    override fun promote(session: StoredDeviceSession) {
        value = session
        pendingLogin = null
        pendingRedeem = null
        pendingRotation = null
    }
    override fun clear() {
        value = null
        pendingLogin = null
        pendingRedeem = null
        pendingRotation = null
    }
}

/** Scripted transport: queue responses or errors, then inspect what was sent. */
class FakeTransport : DeviceSessionTransport {
    data class Call(val path: String, val body: String?, val bearer: String?, val method: String)

    val calls = mutableListOf<Call>()
    val responses = ArrayDeque<SessionResponse>()
    val errors = ArrayDeque<Exception>()
    var afterCall: (() -> Unit)? = null

    override suspend fun send(path: String, body: String?, bearer: String?, method: String): SessionResponse {
        calls += Call(path, body, bearer, method)
        if (errors.isNotEmpty()) throw errors.removeFirst()
        return responses.removeFirst().also { afterCall?.invoke() }
    }
}

fun testPair(
    access: String = "mta_at_access",
    refresh: String = "mta_rt_current",
    expiresAt: String = "2026-09-30T00:15:00Z",
    userId: String = "user-uuid",
) = DeviceSessionPair(
    sessionId = "session-uuid",
    userId = userId,
    accessToken = access,
    accessExpiresAt = expiresAt,
    refreshToken = refresh,
    inactiveExpiresAt = "2027-09-30T00:00:00Z",
)

fun encodePair(pair: DeviceSessionPair): String = kotlinx.serialization.json.Json.encodeToString(pair)

fun errorBody(error: String, message: String = "message", code: Int = 400) =
    """{"error":"$error","message":"$message","code":$code}"""
