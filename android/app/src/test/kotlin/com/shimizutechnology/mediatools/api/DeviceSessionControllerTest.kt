package com.shimizutechnology.mediatools.api

import java.io.IOException
import java.time.Instant
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceSessionControllerTest {
    private val clock = Instant.parse("2026-09-29T00:00:00Z")
    private val firstPair = testPair(access = "mta_at_first", refresh = "mta_rt_first", expiresAt = "2026-09-29T00:00:20Z")
    private val nextToken = "mta_rt_" + "a".repeat(43)

    @Test
    fun `refresh saves next credential first and concurrent callers share rotation`() = runTest {
        val store = FakeSessionStore(StoredDeviceSession(firstPair))
        val transport = FakeTransport().apply {
            responses += SessionResponse(200, encodePair(testPair(access = "mta_at_next", refresh = nextToken, expiresAt = "2026-09-29T00:15:00Z")))
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
        val store = FakeSessionStore(StoredDeviceSession(firstPair))
        val interrupted = FakeTransport().apply { errors += IOException("response lost") }

        assertTrue(runCatching { controller(store, interrupted).token("user-uuid") }.isFailure)
        assertEquals(nextToken, store.value?.pendingNextRefreshToken)

        val recovered = FakeTransport().apply {
            responses += SessionResponse(200, encodePair(testPair(access = "mta_at_recovered", refresh = nextToken, expiresAt = "2026-09-29T00:15:00Z")))
        }
        val token = controller(store, recovered).token("user-uuid")

        assertEquals("mta_at_recovered", token)
        assertEquals(interrupted.calls.single().body, recovered.calls.single().body)
        assertNull(store.value?.pendingNextRefreshToken)
    }

    @Test
    fun `network failure never signs anyone out`() = runTest {
        val store = FakeSessionStore(StoredDeviceSession(firstPair))
        val transport = FakeTransport().apply {
            errors += IOException("offline")
            errors += java.net.SocketTimeoutException("timeout")
        }
        val controller = controller(store, transport)

        repeat(2) { assertTrue(runCatching { controller.token("user-uuid") }.exceptionOrNull() is IOException) }

        assertEquals("user-uuid", controller.currentOwnerId())
        assertNotNull(store.value)
        assertEquals(nextToken, store.value?.pendingNextRefreshToken)
    }

    @Test
    fun `overload and throttling responses keep the session`() = runTest {
        for (status in listOf(429, 500, 502, 503)) {
            val store = FakeSessionStore(StoredDeviceSession(firstPair))
            val transport = FakeTransport().apply { responses += SessionResponse(status, errorBody("authentication_unavailable", code = status)) }
            val controller = controller(store, transport)

            assertTrue(runCatching { controller.token("user-uuid") }.isFailure)

            assertEquals("status $status", "user-uuid", controller.currentOwnerId())
            assertNotNull(store.value)
        }
    }

    @Test
    fun `session_refresh_in_progress retries the identical request then succeeds`() = runTest {
        val store = FakeSessionStore(StoredDeviceSession(firstPair))
        val transport = FakeTransport().apply {
            responses += SessionResponse(409, errorBody("session_refresh_in_progress", code = 409))
            responses += SessionResponse(200, encodePair(testPair(access = "mta_at_next", refresh = nextToken, expiresAt = "2026-09-29T00:15:00Z")))
        }
        val controller = controller(store, transport)

        assertEquals("mta_at_next", controller.token("user-uuid"))

        assertEquals(2, transport.calls.size)
        assertEquals(transport.calls[0].body, transport.calls[1].body)
        assertNull(store.value?.pendingNextRefreshToken)
    }

    @Test
    fun `persistent session_refresh_in_progress is retryable and never signs out`() = runTest {
        val store = FakeSessionStore(StoredDeviceSession(firstPair))
        val transport = FakeTransport().apply {
            repeat(3) { responses += SessionResponse(409, errorBody("session_refresh_in_progress", code = 409)) }
        }
        val controller = controller(store, transport)

        val error = runCatching { controller.token("user-uuid") }.exceptionOrNull() as MediaToolsAPIException

        assertEquals("session_refresh_in_progress", error.errorCode)
        assertTrue(error.isTransientAuthFailure())
        assertEquals("user-uuid", controller.currentOwnerId())
        // The same old/new pair stays saved so the next call retries it.
        assertEquals(nextToken, store.value?.pendingNextRefreshToken)
        assertEquals(3, transport.calls.size)
    }

    @Test
    fun `only a 401 from refresh ends the session`() = runTest {
        val store = FakeSessionStore(StoredDeviceSession(firstPair))
        val transport = FakeTransport().apply { responses += SessionResponse(401, errorBody("invalid_session", code = 401)) }
        val controller = controller(store, transport)

        assertTrue(runCatching { controller.token("user-uuid") }.isFailure)

        assertNull(controller.currentOwnerId())
        assertNotNull(store.value)
    }

    @Test
    fun `stored session from an earlier build still refreshes and keeps its migration pair`() = runTest {
        // Exactly what AndroidDeviceSessionStore wrote before this change, including the old field name.
        val legacyJson = """{"pair":${encodePair(firstPair)},"verifiedClerkId":"legacy-id","pendingNextRefreshToken":"$nextToken","unknownFutureField":1}"""
        val decoded = Json { ignoreUnknownKeys = true }.decodeFromString<StoredDeviceSession>(legacyJson)
        val store = FakeSessionStore(decoded)
        val transport = FakeTransport().apply {
            responses += SessionResponse(200, encodePair(testPair(access = "mta_at_next", refresh = nextToken, expiresAt = "2026-09-29T00:15:00Z")))
        }
        val controller = controller(store, transport)

        assertEquals("legacy-id" to "user-uuid", controller.verifiedMigration)
        assertEquals("mta_at_next", controller.token("user-uuid"))
        assertEquals("legacy-id", store.value?.legacyOwnerId)
        assertTrue(Json.encodeToString(store.value!!).contains("\"verifiedClerkId\":\"legacy-id\""))
    }

    @Test
    fun `sign out requires server revocation before clearing local credential`() = runTest {
        val store = FakeSessionStore(StoredDeviceSession(firstPair.copy(accessExpiresAt = "2027-01-01T00:00:00Z")))
        val transport = FakeTransport().apply { responses += SessionResponse(503, "") }
        val controller = controller(store, transport)

        assertTrue(runCatching { controller.revokeAndClear() }.isFailure)
        assertNotNull(store.value)
        assertEquals("user-uuid", controller.currentOwnerId())

        transport.responses += SessionResponse(204, "")
        controller.revokeAndClear()
        assertNull(store.value)
        assertNull(controller.currentOwnerId())
        assertEquals("DELETE", transport.calls.last().method)
    }

    @Test
    fun `rejected refresh still revokes with unexpired access credential`() = runTest {
        val store = FakeSessionStore(StoredDeviceSession(firstPair.copy(accessExpiresAt = "2027-01-01T00:00:00Z")))
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
    }

    @Test
    fun `sign out retains rejected expired credential when refresh fails again`() = runTest {
        val store = FakeSessionStore(StoredDeviceSession(firstPair))
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

    @Test
    fun `installing a session clears every pending journal and refuses to replace a live one`() = runTest {
        val store = FakeSessionStore(
            pendingLogin = PendingPasswordLogin("a@example.com", nextToken, "Pixel"),
            pendingRedeem = PendingRecoveryCodeRedeem("MTR-OLD", nextToken),
            pendingRotation = PendingRecoveryCodeRotation("other-user", "old-rotation", listOf("MTR-OLD")),
        )
        val controller = controller(store, FakeTransport())
        val pair = testPair(refresh = nextToken)

        controller.installSession(pair, nextToken)

        assertEquals("user-uuid", controller.currentOwnerId())
        assertNull(store.pendingLogin)
        assertNull(store.pendingRedeem)
        assertNull(store.pendingRotation)
        val second = runCatching { controller.installSession(testPair(refresh = nextToken, userId = "other"), nextToken) }
        assertTrue(second.isFailure)
        assertEquals("user-uuid", controller.currentOwnerId())
    }

    @Test
    fun `a rejected session can be replaced by a fresh sign-in`() = runTest {
        val store = FakeSessionStore(StoredDeviceSession(firstPair))
        val transport = FakeTransport().apply { responses += SessionResponse(401, "") }
        val controller = controller(store, transport)
        assertTrue(runCatching { controller.token("user-uuid") }.isFailure)

        controller.installSession(testPair(userId = "user-b", refresh = nextToken), nextToken)

        assertEquals("user-b", controller.currentOwnerId())
        assertEquals("user-b", store.value?.pair?.userId)
    }

    @Test
    fun `invalid session responses are never installed`() = runTest {
        val invalid = listOf(
            testPair(userId = "", refresh = nextToken),
            testPair(refresh = "mta_rt_wrong"),
            testPair(access = "not-an-access-token", refresh = nextToken),
        )
        for (pair in invalid) {
            val store = FakeSessionStore()
            val result = runCatching { controller(store, FakeTransport()).installSession(pair, nextToken) }
            assertTrue(result.isFailure)
            assertNull(store.value)
        }
        assertFalse(invalid.isEmpty())
    }

    private fun controller(store: FakeSessionStore, transport: FakeTransport) = DeviceSessionController(
        store,
        transport,
        now = { clock },
        randomRefreshToken = { nextToken },
    )
}
