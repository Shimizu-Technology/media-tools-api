package com.shimizutechnology.mediatools.api

import java.io.IOException
import java.time.Instant
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceSessionControllerTest {
    private val clock = Instant.parse("2026-09-29T00:00:00Z")
    private val firstPair = pair(access = "mta_at_first", refresh = "mta_rt_first")
    private val nextToken = "mta_rt_" + "a".repeat(43)

    @Test
    fun `verified Clerk bootstrap records stable server owner`() = runTest {
        val store = MemorySessionStore()
        val transport = FakeTransport().apply {
            responses += SessionResponse(201, encode(firstPair.copy(refreshToken = nextToken)))
        }
        val controller = controller(store, transport)

        controller.bootstrap("clerk-a", "verified-clerk-token", "Pixel")

        assertEquals("user-uuid", controller.currentOwnerId())
        assertEquals("clerk-a" to "user-uuid", controller.verifiedMigration)
        assertEquals("/auth/session/bootstrap", transport.calls.single().path)
        assertEquals("verified-clerk-token", transport.calls.single().bearer)
        assertTrue(transport.calls.single().body!!.contains("\"client_type\":\"android\""))
        assertTrue(transport.calls.single().body!!.contains("\"next_refresh_token\":\"$nextToken\""))
        assertNull(store.pendingBootstrap)
    }

    @Test
    fun `lost bootstrap response retries byte equivalent request after relaunch`() = runTest {
        val store = MemorySessionStore()
        val interrupted = FakeTransport().apply { errors += IOException("response lost") }

        assertTrue(runCatching {
            controller(store, interrupted).bootstrap("clerk-a", "first-clerk-token", " Pixel 9 ")
        }.isFailure)
        assertNotNull(store.pendingBootstrap)
        val pending = requireNotNull(store.pendingBootstrap)
        assertEquals("clerk-a", pending.verifiedClerkId)
        assertEquals(nextToken, pending.nextRefreshToken)
        assertNull(store.value)

        val recovered = FakeTransport().apply {
            responses += SessionResponse(201, encode(firstPair.copy(refreshToken = nextToken)))
        }
        val pair = controller(store, recovered).bootstrap("clerk-a", "renewed-clerk-token", "Changed model")

        assertEquals(firstPair.sessionId, pair.sessionId)
        assertEquals(interrupted.calls.single().body, recovered.calls.single().body)
        assertEquals("Pixel 9", pending.deviceName)
        assertEquals("renewed-clerk-token", recovered.calls.single().bearer)
        assertNull(store.pendingBootstrap)
        assertEquals(nextToken, store.value?.pair?.refreshToken)
    }

    @Test
    fun `transient bootstrap failure retains journal for exact retry`() = runTest {
        for (status in listOf(404, 429, 503)) {
            val store = MemorySessionStore()
            val unavailable = FakeTransport().apply { responses += SessionResponse(status, "") }

            assertTrue(runCatching {
                controller(store, unavailable).bootstrap("clerk-a", "clerk-token", "Pixel")
            }.isFailure)
            assertNotNull("status $status must retain the recoverable successor", store.pendingBootstrap)

            val recovered = FakeTransport().apply {
                responses += SessionResponse(201, encode(firstPair.copy(refreshToken = nextToken)))
            }
            controller(store, recovered).bootstrap("clerk-a", "fresh-clerk-token", "Pixel")

            assertEquals(unavailable.calls.single().body, recovered.calls.single().body)
            assertNull(store.pendingBootstrap)
            assertNotNull(store.value)
        }
    }

    @Test
    fun `definitive bootstrap rejection clears pending successor`() = runTest {
        for (status in listOf(400, 401)) {
            val store = MemorySessionStore()
            val transport = FakeTransport().apply { responses += SessionResponse(status, "") }

            assertTrue(runCatching {
                controller(store, transport).bootstrap("clerk-a", "clerk-token", "Pixel")
            }.isFailure)

            assertNull("status $status must clear the unusable successor", store.pendingBootstrap)
            assertNull(store.value)
        }
    }

    @Test
    fun `invalid bootstrap response never installs a session`() = runTest {
        val invalidPairs = listOf(
            firstPair.copy(userId = "", refreshToken = nextToken),
            firstPair.copy(sessionId = "", refreshToken = nextToken),
            firstPair.copy(refreshToken = "mta_rt_wrong"),
        )
        for (pair in invalidPairs) {
            val store = MemorySessionStore()
            val transport = FakeTransport().apply { responses += SessionResponse(201, encode(pair)) }

            assertTrue(runCatching {
                controller(store, transport).bootstrap("clerk-a", "clerk-token", "Pixel")
            }.isFailure)

            assertNull(store.value)
            assertEquals(nextToken, store.pendingBootstrap?.nextRefreshToken)
        }
    }

    @Test
    fun `Clerk identity switch cannot reuse pending bootstrap successor`() = runTest {
        var clerkId = "clerk-a"
        val oldSuccessor = "mta_rt_" + "a".repeat(43)
        val newSuccessor = "mta_rt_" + "b".repeat(43)
        val store = MemorySessionStore()
        val interrupted = FakeTransport().apply { errors += IOException("response lost") }
        assertTrue(runCatching {
            controller(store, interrupted, externalIdentity = { clerkId }, refreshToken = oldSuccessor)
                .bootstrap("clerk-a", "clerk-a-token", "Pixel")
        }.isFailure)

        clerkId = "clerk-b"
        val switched = FakeTransport().apply {
            responses += SessionResponse(201, encode(firstPair.copy(refreshToken = newSuccessor)))
        }
        controller(store, switched, externalIdentity = { clerkId }, refreshToken = newSuccessor)
            .bootstrap("clerk-b", "clerk-b-token", "Pixel")

        assertTrue(interrupted.calls.single().body!!.contains(oldSuccessor))
        assertFalse(switched.calls.single().body!!.contains(oldSuccessor))
        assertTrue(switched.calls.single().body!!.contains(newSuccessor))
        assertEquals("clerk-b", store.value?.verifiedClerkId)
        assertNull(store.pendingBootstrap)
    }

    @Test
    fun `identity change while bootstrap is in flight prevents session install`() = runTest {
        var clerkId = "clerk-a"
        val store = MemorySessionStore()
        val transport = FakeTransport().apply {
            responses += SessionResponse(201, encode(firstPair.copy(refreshToken = nextToken)))
            afterCall = { clerkId = "clerk-b" }
        }

        assertTrue(runCatching {
            controller(store, transport, externalIdentity = { clerkId })
                .bootstrap("clerk-a", "clerk-a-token", "Pixel")
        }.isFailure)

        assertNull(store.value)
        assertEquals("clerk-a", store.pendingBootstrap?.verifiedClerkId)
        assertEquals(nextToken, store.pendingBootstrap?.nextRefreshToken)
    }

    @Test
    fun `refresh saves next credential first and concurrent callers share rotation`() = runTest {
        val store = MemorySessionStore(StoredDeviceSession(firstPair, "clerk-a"))
        val transport = FakeTransport().apply {
            responses += SessionResponse(200, encode(pair(access = "mta_at_next", refresh = nextToken, expiresAt = "2026-09-29T00:15:00Z")))
        }
        val controller = controller(store, transport)

        val results = listOf(
            async { controller.token("user-uuid", forceRefresh = false) },
            async { controller.token("user-uuid", forceRefresh = false) },
        ).awaitAll()

        assertEquals(listOf("mta_at_next", "mta_at_next"), results)
        assertEquals(1, transport.calls.size)
        assertTrue(transport.calls.single().body!!.contains("\"next_refresh_token\":\"$nextToken\""))
        assertNull(store.value?.pendingNextRefreshToken)
        assertEquals(nextToken, store.value?.pair?.refreshToken)
    }

    @Test
    fun `interrupted refresh retries the same old and next pair after relaunch`() = runTest {
        val store = MemorySessionStore(StoredDeviceSession(firstPair, "clerk-a"))
        val interrupted = FakeTransport().apply { errors += IOException("response lost") }

        assertTrue(runCatching { controller(store, interrupted).token("user-uuid") }.isFailure)
        assertEquals(nextToken, store.value?.pendingNextRefreshToken)

        val recovered = FakeTransport().apply {
            responses += SessionResponse(200, encode(pair(access = "mta_at_recovered", refresh = nextToken)))
        }
        val token = controller(store, recovered).token("user-uuid")

        assertEquals("mta_at_recovered", token)
        assertTrue(interrupted.calls.single().body!!.contains(nextToken))
        assertEquals(interrupted.calls.single().body, recovered.calls.single().body)
        assertNull(store.value?.pendingNextRefreshToken)
    }

    @Test
    fun `account switch cannot borrow first party credential`() = runTest {
        var clerkId: String? = "clerk-a"
        val store = MemorySessionStore(StoredDeviceSession(firstPair, "clerk-a"))
        val controller = controller(store, FakeTransport(), externalIdentity = { clerkId })

        clerkId = "clerk-b"

        assertTrue(controller.hasConflictingExternalIdentity(clerkId))
        assertNull(controller.currentOwnerId())
        assertTrue(runCatching { controller.token("user-uuid") }.exceptionOrNull() is MediaToolsAPIException)
        assertEquals("clerk-a", store.value?.verifiedClerkId)
    }

    @Test
    fun `sign out requires server revocation before clearing local credential`() = runTest {
        val clerkId: String? = "clerk-b"
        val store = MemorySessionStore(StoredDeviceSession(firstPair.copy(accessExpiresAt = "2027-01-01T00:00:00Z"), "clerk-a"))
        val transport = FakeTransport().apply { responses += SessionResponse(503, "") }
        val controller = controller(store, transport, externalIdentity = { clerkId })

        assertTrue(controller.hasConflictingExternalIdentity(clerkId))
        assertTrue(runCatching { controller.revokeAndClear() }.isFailure)
        assertNotNull(store.value)
        assertTrue(controller.hasConflictingExternalIdentity(clerkId))

        transport.responses += SessionResponse(204, "")
        controller.revokeAndClear()
        assertNull(store.value)
        assertFalse(controller.hasConflictingExternalIdentity(clerkId))
        assertNull(controller.currentOwnerId())
        assertEquals("DELETE", transport.calls.last().method)
    }

    @Test
    fun `refresh rejection suspends credential without moving ownership`() = runTest {
        val store = MemorySessionStore(StoredDeviceSession(firstPair, "clerk-a"))
        val transport = FakeTransport().apply { responses += SessionResponse(401, "") }
        val controller = controller(store, transport)

        assertTrue(runCatching { controller.token("user-uuid") }.isFailure)
        assertNull(controller.currentOwnerId())
        assertNotNull(store.value)
        assertFalse(store.value?.verifiedClerkId.isNullOrBlank())
    }

    @Test
    fun `rejected refresh still revokes with unexpired access credential`() = runTest {
        val store = MemorySessionStore(StoredDeviceSession(firstPair.copy(accessExpiresAt = "2027-01-01T00:00:00Z"), "clerk-a"))
        val transport = FakeTransport().apply { responses += SessionResponse(401, "") }
        val controller = controller(store, transport)
        assertTrue(runCatching { controller.token("user-uuid", forceRefresh = true) }.isFailure)

        transport.responses += SessionResponse(503, "")
        assertTrue(runCatching { controller.revokeAndClear() }.isFailure)
        assertNotNull(store.value)
        assertNull(controller.currentOwnerId())
        assertEquals("DELETE", transport.calls.last().method)
        assertEquals(firstPair.accessToken, transport.calls.last().bearer)

        transport.responses += SessionResponse(204, "")
        controller.revokeAndClear()
        assertNull(store.value)
        assertEquals("DELETE", transport.calls.last().method)
    }

    @Test
    fun `sign out retains rejected expired credential when refresh fails again`() = runTest {
        val store = MemorySessionStore(StoredDeviceSession(firstPair, "clerk-a"))
        val transport = FakeTransport().apply {
            responses += SessionResponse(401, "")
            responses += SessionResponse(401, "")
        }
        val controller = controller(store, transport)
        assertTrue(runCatching { controller.token("user-uuid") }.isFailure)

        assertTrue(runCatching { controller.revokeAndClear() }.isFailure)

        assertNotNull(store.value)
        assertNull(controller.currentOwnerId())
        assertTrue(transport.calls.all { it.path == "/auth/session/refresh" })
        assertEquals(transport.calls.first().body, transport.calls.last().body)
    }

    private fun controller(
        store: MemorySessionStore,
        transport: FakeTransport,
        externalIdentity: () -> String? = { "clerk-a" },
        refreshToken: String = nextToken,
    ) = DeviceSessionController(
        store,
        transport,
        now = { clock },
        randomRefreshToken = { refreshToken },
        currentExternalIdentity = externalIdentity,
    )

    private fun pair(access: String, refresh: String, expiresAt: String = "2026-09-29T00:00:20Z") = DeviceSessionPair(
        sessionId = "session-uuid",
        userId = "user-uuid",
        accessToken = access,
        accessExpiresAt = expiresAt,
        refreshToken = refresh,
        inactiveExpiresAt = "2027-09-29T00:00:00Z",
    )

    private fun encode(pair: DeviceSessionPair): String = kotlinx.serialization.json.Json.encodeToString(pair)
}

private class MemorySessionStore(
    var value: StoredDeviceSession? = null,
    var pendingBootstrap: PendingDeviceSessionBootstrap? = null,
) : DeviceSessionStore {
    override fun load(): StoredDeviceSession? = value
    override fun save(session: StoredDeviceSession) { value = session }
    override fun loadPendingBootstrap(): PendingDeviceSessionBootstrap? = pendingBootstrap
    override fun savePendingBootstrap(pending: PendingDeviceSessionBootstrap) { pendingBootstrap = pending }
    override fun promoteBootstrap(session: StoredDeviceSession) {
        value = session
        pendingBootstrap = null
    }
    override fun clearPendingBootstrap() { pendingBootstrap = null }
    override fun clear() {
        value = null
        pendingBootstrap = null
    }
}

private class FakeTransport : DeviceSessionTransport {
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
