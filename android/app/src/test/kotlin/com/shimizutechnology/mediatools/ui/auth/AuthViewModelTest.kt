package com.shimizutechnology.mediatools.ui.auth

import com.shimizutechnology.mediatools.api.DeviceSessionController
import com.shimizutechnology.mediatools.api.FakeSessionStore
import com.shimizutechnology.mediatools.api.FakeTransport
import com.shimizutechnology.mediatools.api.GENERIC_EMAIL_RECEIPT
import com.shimizutechnology.mediatools.api.PasswordAuthController
import com.shimizutechnology.mediatools.api.SessionResponse
import com.shimizutechnology.mediatools.api.encodePair
import com.shimizutechnology.mediatools.api.errorBody
import com.shimizutechnology.mediatools.api.testPair
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AuthViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private val successor = "mta_rt_" + "v".repeat(43)
    private val password = "correct horse battery staple"
    private var clock = 1_000_000L

    @Before fun setUp() { Dispatchers.setMain(dispatcher) }
    @After fun tearDown() { Dispatchers.resetMain() }

    private val receipt = SessionResponse(202, """{"message":"$GENERIC_EMAIL_RECEIPT"}""")
    private val health = { open: Boolean -> SessionResponse(200, """{"status":"ok","signup_enabled":$open}""") }

    @Test
    fun `sign-up is offered only when the server says it is open`() = runTest(dispatcher) {
        val open = viewModel(FakeTransport().apply { responses += health(true) })
        val closed = viewModel(FakeTransport().apply { responses += health(false) })
        val unreachable = viewModel(FakeTransport().apply { errors += IOException("offline") })
        advanceUntilIdle()

        assertTrue(open.state.value.signupEnabled)
        assertFalse(closed.state.value.signupEnabled)
        assertFalse(unreachable.state.value.signupEnabled)
    }

    @Test
    fun `closed sign-up cannot be started and sends no request`() = runTest(dispatcher) {
        val transport = FakeTransport().apply { responses += health(false) }
        val vm = viewModel(transport)
        advanceUntilIdle()
        vm.setEmail("a@example.com")

        vm.startSignup(null)
        advanceUntilIdle()

        assertEquals(AuthStep.SignIn, vm.state.value.step)
        assertEquals(1, transport.calls.size)
        assertEquals("Sign-up is not open yet.", vm.state.value.error)
    }

    @Test
    fun `initiation shows the same generic receipt for every address`() = runTest(dispatcher) {
        val states = listOf("new@example.com", "registered@example.com").map { address ->
            val vm = viewModel(FakeTransport().apply { responses += health(true); responses += receipt })
            advanceUntilIdle()
            vm.setEmail(address)
            vm.startSignup("Pat")
            advanceUntilIdle()
            vm.state.value.copy(email = "")
        }

        assertEquals(states[0], states[1])
        assertEquals(AuthStep.SignUpCode, states[0].step)
        assertEquals(GENERIC_EMAIL_RECEIPT, states[0].notice)
        assertNull(states[0].error)
        assertEquals(clock + AuthViewModel.RESEND_COOLDOWN_MILLIS, states[0].resendAvailableAtMillis)
    }

    @Test
    fun `forgot password uses the receipt too and does not depend on the account`() = runTest(dispatcher) {
        val vm = viewModel(FakeTransport().apply { responses += health(false); responses += receipt })
        advanceUntilIdle()
        vm.setEmail("nobody@example.com")

        vm.startReset()
        advanceUntilIdle()

        assertEquals(AuthStep.ResetCode, vm.state.value.step)
        assertEquals(GENERIC_EMAIL_RECEIPT, vm.state.value.notice)
    }

    @Test
    fun `resend waits out the cooldown and honors a throttled Retry-After`() = runTest(dispatcher) {
        val transport = FakeTransport().apply { responses += health(true); responses += receipt }
        val vm = viewModel(transport)
        advanceUntilIdle()
        vm.setEmail("a@example.com")
        vm.startSignup(null)
        advanceUntilIdle()
        assertEquals(2, transport.calls.size)

        vm.resendCode()
        advanceUntilIdle()
        assertEquals("too early: no request", 2, transport.calls.size)

        clock += AuthViewModel.RESEND_COOLDOWN_MILLIS
        transport.responses += SessionResponse(429, errorBody("rate_limit_exceeded", code = 429), retryAfterSeconds = 120)
        vm.resendCode()
        advanceUntilIdle()

        assertEquals(3, transport.calls.size)
        assertEquals("/auth/signup", transport.calls.last().path)
        assertEquals(clock + 120_000L, vm.state.value.resendAvailableAtMillis)
        assertTrue(vm.state.value.error!!.contains("2 minutes"))
        // The receipt and the code step stay in place so nothing typed is lost.
        assertEquals(AuthStep.SignUpCode, vm.state.value.step)
        assertEquals(GENERIC_EMAIL_RECEIPT, vm.state.value.notice)
    }

    @Test
    fun `verified sign-up signs in with the chosen password`() = runTest(dispatcher) {
        val store = FakeSessionStore()
        val transport = FakeTransport().apply {
            responses += health(true)
            responses += receipt
            responses += SessionResponse(200, """{"verified":true,"sign_in_required":true}""")
            responses += SessionResponse(201, encodePair(testPair(refresh = successor)))
        }
        val (vm, session) = viewModelAndSession(store, transport)
        advanceUntilIdle()
        vm.setEmail("a@example.com")
        vm.startSignup(null)
        advanceUntilIdle()

        vm.completeSignup("123456", password)
        advanceUntilIdle()

        assertEquals(
            listOf("/health", "/auth/signup", "/auth/signup/verify", "/auth/password/login"),
            transport.calls.map { it.path },
        )
        assertEquals("user-uuid", session.currentOwnerId())
        assertNull(vm.state.value.error)
        assertFalse(vm.state.value.busy)
    }

    @Test
    fun `verified account with a failed auto sign-in falls back to sign-in without an error`() = runTest(dispatcher) {
        val transport = FakeTransport().apply {
            responses += health(true)
            responses += SessionResponse(200, """{"verified":true,"sign_in_required":true}""")
        }
        val vm = viewModel(transport)
        advanceUntilIdle()
        vm.setEmail("a@example.com")
        // Queued after the availability check so only the automatic sign-in loses its response.
        transport.afterCall = { if (transport.calls.last().path == "/auth/signup/verify") transport.errors += IOException("offline") }

        vm.completeReset("123456", password)
        advanceUntilIdle()

        assertEquals(AuthStep.SignIn, vm.state.value.step)
        assertNotNull(vm.state.value.notice)
        assertNull(vm.state.value.error)
        assertFalse(vm.state.value.busy)
    }

    @Test
    fun `wrong code keeps the person on the code step and never signs in`() = runTest(dispatcher) {
        val transport = FakeTransport().apply {
            responses += health(false)
            responses += receipt
            responses += SessionResponse(400, errorBody("invalid_code"))
        }
        val vm = viewModel(transport)
        advanceUntilIdle()
        vm.setEmail("a@example.com")
        vm.startReset()
        advanceUntilIdle()

        vm.completeReset("000000", password)
        advanceUntilIdle()

        assertEquals(AuthStep.ResetCode, vm.state.value.step)
        assertTrue(vm.state.value.error!!.contains("wrong or has expired"))
        assertEquals(GENERIC_EMAIL_RECEIPT, vm.state.value.notice)
        assertTrue(transport.calls.none { it.path == "/auth/password/login" })
    }

    @Test
    fun `sign-in failure keeps the form and a second tap while busy is ignored`() = runTest(dispatcher) {
        val transport = FakeTransport().apply {
            responses += health(false)
            responses += SessionResponse(401, errorBody("invalid_credentials", code = 401))
        }
        val vm = viewModel(transport)
        advanceUntilIdle()
        vm.setEmail("a@example.com")

        vm.signIn(password)
        vm.signIn(password)
        assertTrue(vm.state.value.busy)
        advanceUntilIdle()

        assertEquals(2, transport.calls.size)
        assertEquals("Email or password is incorrect.", vm.state.value.error)
        assertEquals("a@example.com", vm.state.value.email)
        assertEquals(AuthStep.SignIn, vm.state.value.step)
        assertFalse(vm.state.value.busy)
    }

    @Test
    fun `network failure while signing in only shows a retryable message`() = runTest(dispatcher) {
        val store = FakeSessionStore()
        val transport = FakeTransport().apply { responses += health(false) }
        val (vm, session) = viewModelAndSession(store, transport)
        advanceUntilIdle()
        transport.errors += IOException("offline")
        vm.setEmail("a@example.com")

        vm.signIn(password)
        advanceUntilIdle()

        assertTrue(vm.state.value.error!!.startsWith("Could not reach Media Tools"))
        assertNull(session.currentOwnerId())
        // The saved successor lets the retry recover a session whose response was lost.
        assertNotNull(store.pendingLogin)
    }

    @Test
    fun `moving between screens clears messages and the resend wait`() = runTest(dispatcher) {
        val vm = viewModel(FakeTransport().apply { responses += health(false); responses += receipt })
        advanceUntilIdle()
        vm.setEmail("a@example.com")
        vm.startReset()
        advanceUntilIdle()

        vm.go(AuthStep.SignIn)

        assertNull(vm.state.value.notice)
        assertNull(vm.state.value.error)
        assertEquals(0L, vm.state.value.resendAvailableAtMillis)
    }

    private fun viewModel(transport: FakeTransport) = viewModelAndSession(FakeSessionStore(), transport).first

    private fun viewModelAndSession(
        store: FakeSessionStore,
        transport: FakeTransport,
    ): Pair<AuthViewModel, DeviceSessionController> {
        val session = DeviceSessionController(store, transport, randomRefreshToken = { successor })
        val auth = PasswordAuthController(store, transport, session, deviceName = { "Pixel 9" }, randomRefreshToken = { successor })
        return AuthViewModel(auth, nowMillis = { clock }) to session
    }
}
