package com.shimizutechnology.mediatools.api

import java.io.IOException
import java.time.Instant
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecoveryAuthControllerTest {
    private val nextToken = "mta_rt_" + "r".repeat(43)

    @Test
    fun `lost redeem response retries exact code and successor after relaunch`() = runTest {
        val store = RecoveryMemoryStore(
            bootstrap = PendingDeviceSessionBootstrap("clerk-old", "mta_rt_old", "Old phone"),
        )
        val lost = RecoveryFakeTransport().apply { errors += IOException("response lost") }
        val firstDeviceSession = deviceSession(store, lost)
        val first = recovery(store, lost, firstDeviceSession)

        assertTrue(runCatching { first.redeem("  mtr-abcd  ") }.isFailure)
        assertEquals("MTRABCD", store.pendingRedeem?.code)
        assertEquals(nextToken, store.pendingRedeem?.nextRefreshToken)
        assertNull(store.session)

        val recovered = RecoveryFakeTransport().apply {
            responses += SessionResponse(201, Json.encodeToString(pair(refresh = nextToken)))
        }
        val relaunchedDeviceSession = deviceSession(store, recovered)
        recovery(store, recovered, relaunchedDeviceSession).redeem("mtr-abcd")

        assertEquals(lost.calls.single().body, recovered.calls.single().body)
        assertTrue(recovered.calls.single().body!!.contains("\"client_type\":\"android\""))
        assertEquals("user-a", relaunchedDeviceSession.currentOwnerId())
        assertNull(store.pendingRedeem)
        assertNull(store.bootstrap)
        assertNotNull(store.session)
        assertNull(store.session?.verifiedClerkId)
    }

    @Test
    fun `pending redeem rejects another code and definitive rejection clears it`() = runTest {
        val pending = PendingRecoveryCodeRedeem("MTRFIRST", nextToken)
        val store = RecoveryMemoryStore(pendingRedeem = pending)
        val transport = RecoveryFakeTransport()
        val controller = recovery(store, transport, deviceSession(store, transport))

        val mismatch = runCatching { controller.redeem("MTR-SECOND") }.exceptionOrNull()
        assertTrue(mismatch is MediaToolsAPIException)
        assertEquals(pending, store.pendingRedeem)
        assertTrue(transport.calls.isEmpty())

        transport.responses += SessionResponse(401, "{}")
        val rejected = runCatching { controller.redeem("MTR-FIRST") }.exceptionOrNull()
        assertTrue(rejected is MediaToolsAPIException)
        assertNull(store.pendingRedeem)
        assertNull(store.session)
    }

    @Test
    fun `rotation is stable-user bound and confirm retries after response loss`() = runTest {
        val store = RecoveryMemoryStore(session = StoredDeviceSession(pair(expiresAt = "2027-01-01T00:00:00Z")))
        val beginTransport = RecoveryFakeTransport().apply {
            responses += SessionResponse(
                201,
                """{"rotation_id":"rotation-a","codes":[${(1..10).joinToString(",") { "\"MTR-CODE-$it\"" }}]}""",
            )
        }
        val deviceSession = deviceSession(store, beginTransport)
        val first = recovery(store, beginTransport, deviceSession)
        val codes = first.beginRotation()

        assertEquals(10, codes.size)
        assertEquals("user-a", store.pendingRotation?.userId)
        assertEquals("rotation-a", store.pendingRotation?.rotationId)

        val lostConfirm = RecoveryFakeTransport().apply { errors += IOException("response lost") }
        val relaunched = recovery(store, lostConfirm, deviceSession(store, lostConfirm))
        assertEquals(codes, relaunched.beginRotation())
        assertTrue(lostConfirm.calls.isEmpty())
        assertTrue(runCatching { relaunched.confirmRotation() }.isFailure)
        assertNotNull(store.pendingRotation)

        val retryTransport = RecoveryFakeTransport().apply {
            responses += SessionResponse(200, """{"remaining":10}""")
        }
        val status = recovery(store, retryTransport, deviceSession(store, retryTransport)).confirmRotation()
        assertEquals(10, status.remaining)
        assertTrue(retryTransport.calls.single().body!!.contains("rotation-a"))
        assertNull(store.pendingRotation)
    }

    @Test
    fun `rotation owner mismatch deletes secret journal without a request`() = runTest {
        val store = RecoveryMemoryStore(
            session = StoredDeviceSession(pair(expiresAt = "2027-01-01T00:00:00Z")),
            pendingRotation = PendingRecoveryCodeRotation("user-b", "rotation-b", listOf("MTR-SECRET")),
        )
        val transport = RecoveryFakeTransport()

        val error = runCatching {
            recovery(store, transport, deviceSession(store, transport)).beginRotation()
        }.exceptionOrNull()

        assertTrue(error is MediaToolsAPIException)
        assertNull(store.pendingRotation)
        assertTrue(transport.calls.isEmpty())
    }

    @Test
    fun `authenticated status refreshes one rejected access token`() = runTest {
        val store = RecoveryMemoryStore(
            session = StoredDeviceSession(pair(expiresAt = "2027-01-01T00:00:00Z")),
        )
        val refreshed = pair(
            refresh = "mta_rt_" + "n".repeat(43),
            expiresAt = "2027-01-01T00:15:00Z",
        ).copy(accessToken = "mta_at_refreshed")
        val transport = RecoveryFakeTransport().apply {
            responses += SessionResponse(401, "{}")
            responses += SessionResponse(200, Json.encodeToString(refreshed))
            responses += SessionResponse(200, """{"remaining":7}""")
        }

        val status = recovery(store, transport, deviceSession(store, transport)).status()

        assertEquals(7, status.remaining)
        assertEquals(
            listOf("/auth/recovery", "/auth/session/refresh", "/auth/recovery"),
            transport.calls.map { it.path },
        )
        assertEquals("mta_at_access", transport.calls.first().bearer)
        assertEquals("mta_at_refreshed", transport.calls.last().bearer)
    }

    @Test
    fun `sign out and deletion clear every recovery journal`() = runTest {
        for (delete in listOf(false, true)) {
            val store = RecoveryMemoryStore(
                session = StoredDeviceSession(pair(expiresAt = "2027-01-01T00:00:00Z")),
                pendingRedeem = PendingRecoveryCodeRedeem("MTR-SECRET", nextToken),
                pendingRotation = PendingRecoveryCodeRotation("user-a", "rotation-a", listOf("MTR-SECRET")),
            )
            val transport = RecoveryFakeTransport().apply {
                if (!delete) responses += SessionResponse(204, "")
            }
            val deviceSession = deviceSession(store, transport)

            if (delete) deviceSession.clearAfterDeletion() else deviceSession.revokeAndClear()

            assertNull(store.session)
            assertNull(store.pendingRedeem)
            assertNull(store.pendingRotation)
        }
    }

    private fun recovery(
        store: RecoveryMemoryStore,
        transport: RecoveryFakeTransport,
        deviceSession: DeviceSessionController,
    ) = RecoveryAuthController(
        store,
        transport,
        deviceSession,
        deviceName = { "Pixel 9" },
        randomRefreshToken = { nextToken },
    )

    private fun deviceSession(store: RecoveryMemoryStore, transport: RecoveryFakeTransport) =
        DeviceSessionController(
            store,
            transport,
            now = { Instant.parse("2026-09-30T00:00:00Z") },
            randomRefreshToken = { "mta_rt_" + "n".repeat(43) },
            currentExternalIdentity = { null },
        )

    private fun pair(
        refresh: String = "mta_rt_current",
        expiresAt: String = "2026-09-30T00:15:00Z",
    ) = DeviceSessionPair(
        sessionId = "session-a",
        userId = "user-a",
        accessToken = "mta_at_access",
        accessExpiresAt = expiresAt,
        refreshToken = refresh,
        inactiveExpiresAt = "2027-09-30T00:00:00Z",
    )
}

private class RecoveryMemoryStore(
    var session: StoredDeviceSession? = null,
    var bootstrap: PendingDeviceSessionBootstrap? = null,
    var pendingRedeem: PendingRecoveryCodeRedeem? = null,
    var pendingRotation: PendingRecoveryCodeRotation? = null,
) : DeviceSessionStore {
    override fun load() = session
    override fun save(session: StoredDeviceSession) { this.session = session }
    override fun loadPendingBootstrap() = bootstrap
    override fun savePendingBootstrap(pending: PendingDeviceSessionBootstrap) { bootstrap = pending }
    override fun promoteBootstrap(session: StoredDeviceSession) {
        this.session = session
        bootstrap = null
        pendingRedeem = null
        pendingRotation = null
    }
    override fun clearPendingBootstrap() { bootstrap = null }
    override fun loadPendingRecoveryRedeem() = pendingRedeem
    override fun savePendingRecoveryRedeem(pending: PendingRecoveryCodeRedeem) { pendingRedeem = pending }
    override fun clearPendingRecoveryRedeem() { pendingRedeem = null }
    override fun loadPendingRecoveryRotation() = pendingRotation
    override fun savePendingRecoveryRotation(pending: PendingRecoveryCodeRotation) { pendingRotation = pending }
    override fun clearPendingRecoveryRotation() { pendingRotation = null }
    override fun promoteRecovery(session: StoredDeviceSession) {
        this.session = session
        bootstrap = null
        pendingRedeem = null
        pendingRotation = null
    }
    override fun clear() {
        session = null
        bootstrap = null
        pendingRedeem = null
        pendingRotation = null
    }
}

private class RecoveryFakeTransport : DeviceSessionTransport {
    data class Call(val path: String, val body: String?, val bearer: String?, val method: String)
    val calls = mutableListOf<Call>()
    val responses = ArrayDeque<SessionResponse>()
    val errors = ArrayDeque<Exception>()

    override suspend fun send(path: String, body: String?, bearer: String?, method: String): SessionResponse {
        calls += Call(path, body, bearer, method)
        if (errors.isNotEmpty()) throw errors.removeFirst()
        return responses.removeFirst()
    }
}
