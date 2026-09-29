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
        val transport = FakeTransport().apply { responses += SessionResponse(201, encode(firstPair)) }
        val controller = controller(store, transport)

        controller.bootstrap("clerk-a", "verified-clerk-token", "Pixel")

        assertEquals("user-uuid", controller.currentOwnerId())
        assertEquals("clerk-a" to "user-uuid", controller.verifiedMigration)
        assertEquals("/auth/session/bootstrap", transport.calls.single().path)
        assertEquals("verified-clerk-token", transport.calls.single().bearer)
        assertTrue(transport.calls.single().body!!.contains("\"client_type\":\"android\""))
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

        assertNull(controller.currentOwnerId())
        assertTrue(runCatching { controller.token("user-uuid") }.exceptionOrNull() is MediaToolsAPIException)
        assertEquals("clerk-a", store.value?.verifiedClerkId)
    }

    @Test
    fun `sign out requires server revocation before clearing local credential`() = runTest {
        val store = MemorySessionStore(StoredDeviceSession(firstPair.copy(accessExpiresAt = "2027-01-01T00:00:00Z"), "clerk-a"))
        val transport = FakeTransport().apply { responses += SessionResponse(503, "") }
        val controller = controller(store, transport)

        assertTrue(runCatching { controller.revokeAndClear() }.isFailure)
        assertNotNull(store.value)

        transport.responses += SessionResponse(204, "")
        controller.revokeAndClear()
        assertNull(store.value)
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

    private fun controller(
        store: MemorySessionStore,
        transport: FakeTransport,
        externalIdentity: () -> String? = { null },
    ) = DeviceSessionController(
        store,
        transport,
        now = { clock },
        randomRefreshToken = { nextToken },
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

private class MemorySessionStore(var value: StoredDeviceSession? = null) : DeviceSessionStore {
    override fun load(): StoredDeviceSession? = value
    override fun save(session: StoredDeviceSession) { value = session }
    override fun clear() { value = null }
}

private class FakeTransport : DeviceSessionTransport {
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
