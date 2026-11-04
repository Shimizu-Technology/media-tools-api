package com.shimizutechnology.mediatools.api

import java.io.IOException
import java.time.Instant
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PasswordAuthControllerTest {
    private val nextToken = "mta_rt_" + "p".repeat(43)
    private val otherToken = "mta_rt_" + "q".repeat(43)
    private val password = "correct horse battery staple"

    @Test
    fun `sign in installs the session and keeps no password anywhere`() = runTest {
        val store = FakeSessionStore()
        val transport = FakeTransport().apply { responses += SessionResponse(201, encodePair(testPair(refresh = nextToken))) }
        val (auth, session) = controllers(store, transport)

        auth.signIn("  Person@Example.COM ", password)

        assertEquals("user-uuid", session.currentOwnerId())
        assertNull(store.pendingLogin)
        val call = transport.calls.single()
        assertEquals("/auth/password/login", call.path)
        assertNull(call.bearer)
        assertTrue(call.body!!.contains("\"email\":\"person@example.com\""))
        assertTrue(call.body!!.contains("\"client_type\":\"android\""))
        assertTrue(call.body!!.contains("\"device_name\":\"Pixel 9\""))
        assertTrue(call.body!!.contains("\"next_refresh_token\":\"$nextToken\""))
        assertFalse(store.value.toString().contains(password))
    }

    @Test
    fun `successor is saved before sending and never contains the password`() = runTest {
        val store = FakeSessionStore()
        val transport = FakeTransport().apply {
            afterCall = { assertEquals(nextToken, store.pendingLogin?.nextRefreshToken) }
            errors += IOException("response lost")
        }

        assertTrue(runCatching { controllers(store, transport).first.signIn("a@example.com", password) }.isFailure)

        assertEquals(PendingPasswordLogin("a@example.com", nextToken, "Pixel 9"), store.pendingLogin)
        assertFalse(store.pendingLogin.toString().contains(password))
    }

    @Test
    fun `lost response retries the same request after relaunch and recovers the session`() = runTest {
        val store = FakeSessionStore()
        val lost = FakeTransport().apply { errors += IOException("response lost") }
        assertTrue(runCatching { controllers(store, lost).first.signIn("a@example.com", password) }.isFailure)

        val recovered = FakeTransport().apply { responses += SessionResponse(201, encodePair(testPair(refresh = nextToken))) }
        val (auth, session) = controllers(store, recovered, token = otherToken)
        auth.signIn("A@example.com", password)

        assertEquals(lost.calls.single().body, recovered.calls.single().body)
        assertEquals("user-uuid", session.currentOwnerId())
        assertNull(store.pendingLogin)
    }

    @Test
    fun `a different address never reuses the previous successor`() = runTest {
        val store = FakeSessionStore(pendingLogin = PendingPasswordLogin("a@example.com", nextToken, "Pixel 9"))
        val transport = FakeTransport().apply { errors += IOException("offline") }

        runCatching { controllers(store, transport, token = otherToken).first.signIn("b@example.com", password) }

        assertTrue(transport.calls.single().body!!.contains(otherToken))
        assertFalse(transport.calls.single().body!!.contains(nextToken))
        assertEquals("b@example.com", store.pendingLogin?.email)
    }

    @Test
    fun `rejected password is generic, keeps the journal, and signs nobody in`() = runTest {
        val store = FakeSessionStore()
        val transport = FakeTransport().apply {
            responses += SessionResponse(401, errorBody("invalid_credentials", "Email or password is incorrect", 401))
        }
        val (auth, session) = controllers(store, transport)

        val error = runCatching { auth.signIn("a@example.com", "wrong") }.exceptionOrNull() as MediaToolsAPIException

        assertEquals("invalid_credentials", error.errorCode)
        assertEquals("Email or password is incorrect.", error.authFailureMessage())
        assertNull(session.currentOwnerId())
        assertNull(store.value)
        assertNotNull(store.pendingLogin)
    }

    @Test
    fun `a 400 permanently rejects the saved successor and clears it`() = runTest {
        val store = FakeSessionStore()
        val transport = FakeTransport().apply { responses += SessionResponse(400, errorBody("invalid_request")) }

        assertTrue(runCatching { controllers(store, transport).first.signIn("a@example.com", password) }.isFailure)

        assertNull(store.pendingLogin)
    }

    @Test
    fun `throttling reports Retry-After and keeps the session state and journal`() = runTest {
        val store = FakeSessionStore()
        val transport = FakeTransport().apply {
            responses += SessionResponse(429, errorBody("rate_limit_exceeded", code = 429), retryAfterSeconds = 900)
        }
        val (auth, session) = controllers(store, transport)

        val error = runCatching { auth.signIn("a@example.com", password) }.exceptionOrNull() as MediaToolsAPIException

        assertEquals(900, error.retryAfterSeconds)
        assertEquals("Too many attempts. Try again in about 15 minutes.", error.authFailureMessage())
        assertTrue(error.isTransientAuthFailure())
        assertNull(session.currentOwnerId())
        assertNotNull(store.pendingLogin)
    }

    @Test
    fun `mismatched successor in the response is never installed`() = runTest {
        val store = FakeSessionStore()
        val transport = FakeTransport().apply { responses += SessionResponse(201, encodePair(testPair(refresh = otherToken))) }
        val (auth, session) = controllers(store, transport)

        assertTrue(runCatching { auth.signIn("a@example.com", password) }.isFailure)

        assertNull(session.currentOwnerId())
        assertNull(store.value)
    }

    @Test
    fun `sign in refuses while another account is active and sends nothing`() = runTest {
        val store = FakeSessionStore(StoredDeviceSession(testPair()))
        val transport = FakeTransport()

        val result = runCatching { controllers(store, transport).first.signIn("a@example.com", password) }

        assertTrue(result.isFailure)
        assertTrue(transport.calls.isEmpty())
    }

    @Test
    fun `availability reads signup_enabled and defaults to closed`() = runTest {
        val transport = FakeTransport().apply {
            responses += SessionResponse(200, """{"status":"ok","signup_enabled":true,"password_auth_enabled":true,"auth_capabilities":{"email_codes":true}}""")
            responses += SessionResponse(200, """{"status":"ok"}""")
            responses += SessionResponse(503, "")
        }
        val (auth, _) = controllers(FakeSessionStore(), transport)

        assertTrue(auth.availability().signupEnabled)
        assertFalse(auth.availability().signupEnabled)
        assertTrue(runCatching { auth.availability() }.isFailure)
        assertEquals("/health", transport.calls.first().path)
        assertEquals("GET", transport.calls.first().method)
    }

    @Test
    fun `signup and forgot initiation succeed identically for any address`() = runTest {
        val transport = FakeTransport().apply {
            repeat(4) { responses += SessionResponse(202, """{"message":"$GENERIC_EMAIL_RECEIPT"}""") }
        }
        val (auth, _) = controllers(FakeSessionStore(), transport)

        // New, already-registered, and unknown addresses are indistinguishable to the client.
        auth.startSignup("new@example.com", " Pat ")
        auth.startSignup("existing@example.com")
        auth.startPasswordReset("existing@example.com")
        auth.startPasswordReset("nobody@example.com")

        assertEquals(listOf("/auth/signup", "/auth/signup", "/auth/password/forgot", "/auth/password/forgot"), transport.calls.map { it.path })
        assertEquals("""{"email":"new@example.com","name":"Pat"}""", transport.calls[0].body)
        assertEquals("""{"email":"existing@example.com"}""", transport.calls[1].body)
        assertTrue(transport.calls.all { it.bearer == null })
    }

    @Test
    fun `signup disabled and malformed addresses fail cleanly`() = runTest {
        val transport = FakeTransport().apply { responses += SessionResponse(403, errorBody("signup_disabled", code = 403)) }
        val (auth, _) = controllers(FakeSessionStore(), transport)

        val disabled = runCatching { auth.startSignup("a@example.com") }.exceptionOrNull() as MediaToolsAPIException
        assertEquals("Sign-up is not open yet.", disabled.authFailureMessage())

        val before = transport.calls.size
        assertTrue(runCatching { auth.startSignup("not-an-email") }.isFailure)
        assertTrue(runCatching { auth.startPasswordReset("") }.isFailure)
        assertEquals(before, transport.calls.size)
    }

    @Test
    fun `verification sends digits only and validates locally before any request`() = runTest {
        val transport = FakeTransport().apply {
            responses += SessionResponse(200, """{"verified":true,"sign_in_required":true}""")
            responses += SessionResponse(200, """{"verified":true,"sign_in_required":true}""")
        }
        val (auth, _) = controllers(FakeSessionStore(), transport)

        assertTrue(runCatching { auth.completeSignup("a@example.com", "12345", password) }.isFailure)
        assertTrue(runCatching { auth.completeSignup("a@example.com", "123456", "short") }.isFailure)
        assertTrue(transport.calls.isEmpty())

        auth.completeSignup("a@example.com", " 123 456 ", password)
        auth.completePasswordReset("a@example.com", "654321", password)

        assertEquals("/auth/signup/verify", transport.calls[0].path)
        assertTrue(transport.calls[0].body!!.contains("\"code\":\"123456\""))
        assertEquals("/auth/password/reset", transport.calls[1].path)
    }

    @Test
    fun `wrong or expired code maps to a retryable message`() = runTest {
        val transport = FakeTransport().apply { responses += SessionResponse(400, errorBody("invalid_code")) }
        val error = runCatching {
            controllers(FakeSessionStore(), transport).first.completePasswordReset("a@example.com", "123456", password)
        }.exceptionOrNull() as MediaToolsAPIException

        assertEquals("invalid_code", error.errorCode)
        assertTrue(error.authFailureMessage().contains("request a new one"))
        assertFalse(error.message.contains("123456"))
    }

    @Test
    fun `change password sends the current password and is not replayed when it is wrong`() = runTest {
        val store = FakeSessionStore(StoredDeviceSession(testPair(expiresAt = "2027-01-01T00:00:00Z")))
        val transport = FakeTransport().apply {
            responses += SessionResponse(401, errorBody("current_password_required", code = 401))
            responses += SessionResponse(200, "")
        }
        val (auth, _) = controllers(store, transport)

        val wrong = runCatching { auth.changePassword("nope", password) }.exceptionOrNull() as MediaToolsAPIException
        assertEquals("Your current password is incorrect.", wrong.authFailureMessage())
        assertEquals(1, transport.calls.size)

        auth.changePassword("old password value", password)
        val body = transport.calls.last().body!!
        assertTrue(body.contains("\"current_password\":\"old password value\""))
        assertEquals("/auth/password", transport.calls.last().path)
        assertEquals("mta_at_access", transport.calls.last().bearer)
    }

    @Test
    fun `first password omits current password and an expired access token refreshes once`() = runTest {
        val store = FakeSessionStore(StoredDeviceSession(testPair(expiresAt = "2027-01-01T00:00:00Z")))
        val refreshed = testPair(access = "mta_at_refreshed", refresh = nextToken, expiresAt = "2027-01-01T00:15:00Z")
        val transport = FakeTransport().apply {
            responses += SessionResponse(401, errorBody("invalid_session", code = 401))
            responses += SessionResponse(200, encodePair(refreshed))
            responses += SessionResponse(200, "")
        }
        val (auth, _) = controllers(store, transport)

        auth.changePassword(null, password)

        assertEquals(listOf("/auth/password", "/auth/session/refresh", "/auth/password"), transport.calls.map { it.path })
        assertFalse(transport.calls.last().body!!.contains("current_password"))
        assertEquals("mta_at_refreshed", transport.calls.last().bearer)
    }

    @Test
    fun `password status reads configured`() = runTest {
        val store = FakeSessionStore(StoredDeviceSession(testPair(expiresAt = "2027-01-01T00:00:00Z")))
        val transport = FakeTransport().apply { responses += SessionResponse(200, """{"configured":true,"updated_at":"2026-11-01T00:00:00Z"}""") }

        assertTrue(controllers(store, transport).first.passwordConfigured())
        assertEquals("GET", transport.calls.single().method)
    }

    @Test
    fun `input rules match the server`() {
        assertTrue(isAcceptablePassword("a".repeat(12)))
        assertFalse(isAcceptablePassword("a".repeat(11)))
        assertTrue(isAcceptablePassword("a".repeat(128)))
        assertFalse(isAcceptablePassword("a".repeat(129)))
        // Counted in characters, not UTF-16 units: twelve emoji is twelve characters.
        assertTrue(isAcceptablePassword("😀".repeat(12)))
        assertTrue(looksLikeEmail("person@example.com"))
        assertFalse(looksLikeEmail("person@example"))
        assertFalse(looksLikeEmail("a@@b.com"))
        assertFalse(looksLikeEmail("a b@c.com"))
        assertEquals("person@example.com", normalizeEmail("  Person@Example.COM "))
        assertEquals("123456", normalizeCode(" 123-456 "))
    }

    @Test
    fun `failure copy distinguishes network, throttling, and unavailable`() {
        assertTrue(IOException("x").authFailureMessage().startsWith("Could not reach Media Tools"))
        assertEquals("Too many attempts. Try again in 30 seconds.", MediaToolsAPIException(429, "m", "rate_limit_exceeded", 30).authFailureMessage())
        assertEquals("Too many attempts. Try again in a few minutes.", MediaToolsAPIException(429, "m", "rate_limit_exceeded").authFailureMessage())
        assertTrue(MediaToolsAPIException(503, "m", "authentication_unavailable").authFailureMessage().contains("try again", ignoreCase = true))
        assertFalse(IllegalStateException("boom").isTransientAuthFailure())
    }

    private fun controllers(
        store: FakeSessionStore,
        transport: FakeTransport,
        token: String = nextToken,
    ): Pair<PasswordAuthController, DeviceSessionController> {
        val session = DeviceSessionController(
            store,
            transport,
            now = { Instant.parse("2026-09-30T00:00:00Z") },
            randomRefreshToken = { token },
        )
        return PasswordAuthController(store, transport, session, deviceName = { "Pixel 9" }, randomRefreshToken = { token }) to session
    }
}
