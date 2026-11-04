package com.shimizutechnology.mediatools.ui.auth

import android.os.SystemClock
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.shimizutechnology.mediatools.api.GENERIC_EMAIL_RECEIPT
import com.shimizutechnology.mediatools.api.MediaToolsAPIException
import com.shimizutechnology.mediatools.api.PasswordAuthController
import com.shimizutechnology.mediatools.api.authFailureMessage
import com.shimizutechnology.mediatools.api.looksLikeEmail
import com.shimizutechnology.mediatools.api.normalizeEmail
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

enum class AuthStep { SignIn, SignUp, SignUpCode, ForgotPassword, ResetCode }

/**
 * Passwords and codes are deliberately not part of this state. They live in the screen's
 * memory only, are sent once, and are never saved, logged, or restored.
 */
data class AuthUiState(
    val step: AuthStep = AuthStep.SignIn,
    val email: String = "",
    val signupEnabled: Boolean = false,
    val busy: Boolean = false,
    val error: String? = null,
    val notice: String? = null,
    /** `SystemClock.elapsedRealtime()` millis before which "Resend code" stays disabled; 0 when not waiting. */
    val resendAvailableAtMillis: Long = 0,
)

/**
 * Drives sign-in, sign-up with an emailed code, and password reset. A successful sign-in
 * installs the device session, which the app root observes, so this class has no "done" state.
 */
class AuthViewModel(
    private val auth: PasswordAuthController,
    private val nowMillis: () -> Long = SystemClock::elapsedRealtime,
) : ViewModel() {
    private val _state = MutableStateFlow(AuthUiState())
    val state: StateFlow<AuthUiState> = _state.asStateFlow()

    /** The sign-up name is kept so a resend replaces the pending challenge without losing it. */
    private var signupName: String? = null
    private var checkingAvailability = false

    init {
        refreshAvailability()
    }

    /**
     * Sign-up is offered only when the server says it is open. If the check fails, sign-in
     * still works and sign-up stays hidden until the screen asks again (it does on resume).
     */
    fun refreshAvailability() {
        if (checkingAvailability || _state.value.signupEnabled) return
        checkingAvailability = true
        viewModelScope.launch {
            try {
                val open = runCatching { auth.availability().signupEnabled }.getOrDefault(false)
                _state.update { it.copy(signupEnabled = open) }
            } finally {
                checkingAvailability = false
            }
        }
    }

    fun go(step: AuthStep) {
        // A request in flight finishes on its own step; moving now would be overwritten by it.
        if (_state.value.busy) return
        _state.update { it.copy(step = step, error = null, notice = null, resendAvailableAtMillis = 0) }
    }

    fun setEmail(value: String) {
        _state.update { it.copy(email = value, error = null) }
    }

    fun signIn(password: String) = submit { current ->
        if (!looksLikeEmail(current.email) || password.isEmpty()) {
            fail("Enter your email and password.")
            return@submit
        }
        auth.signIn(current.email, password)
    }

    fun startSignup(name: String?) = submit { current ->
        if (!state.value.signupEnabled) {
            fail("Sign-up is not open yet.")
            return@submit
        }
        signupName = name
        auth.startSignup(current.email, name)
        awaitCode(AuthStep.SignUpCode)
    }

    fun startReset() = submit { current ->
        auth.startPasswordReset(current.email)
        awaitCode(AuthStep.ResetCode)
    }

    fun resendCode() {
        val current = _state.value
        if (current.busy || nowMillis() < current.resendAvailableAtMillis) return
        val signup = current.step == AuthStep.SignUpCode
        submit { c ->
            if (signup) auth.startSignup(c.email, signupName) else auth.startPasswordReset(c.email)
            awaitCode(c.step)
        }
    }

    fun completeSignup(code: String, password: String) = submit { current ->
        auth.completeSignup(current.email, code, password)
        signInAfterProof(current.email, password, "Account created. Sign in with your new password.")
    }

    fun completeReset(code: String, password: String) = submit { current ->
        auth.completePasswordReset(current.email, code, password)
        signInAfterProof(current.email, password, "Password updated. Sign in with your new password.")
    }

    private suspend fun signInAfterProof(email: String, password: String, fallbackNotice: String) {
        try {
            auth.signIn(email, password)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            // The proof itself succeeded and cannot be replayed, so send the person to sign-in.
            _state.update {
                it.copy(step = AuthStep.SignIn, notice = fallbackNotice, error = null, resendAvailableAtMillis = 0)
            }
        }
    }

    /** Always the generic receipt: nothing here depends on whether an account exists. */
    private fun awaitCode(step: AuthStep) {
        _state.update {
            it.copy(
                step = step,
                notice = GENERIC_EMAIL_RECEIPT,
                error = null,
                resendAvailableAtMillis = nowMillis() + RESEND_COOLDOWN_MILLIS,
            )
        }
    }

    private fun fail(message: String) {
        _state.update { it.copy(error = message, notice = null) }
    }

    /** Runs one request at a time, keeps all typed input on failure, and maps errors to copy. */
    private fun submit(block: suspend (AuthUiState) -> Unit) {
        val current = _state.value
        if (current.busy) return
        _state.update { it.copy(busy = true, error = null) }
        viewModelScope.launch {
            try {
                block(_state.value.copy(email = normalizeEmail(_state.value.email)))
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update { state ->
                    val limitedFor = (error as? MediaToolsAPIException)
                        ?.takeIf { it.errorCode == "rate_limit_exceeded" }?.retryAfterSeconds
                    state.copy(
                        error = error.authFailureMessage(),
                        // A throttled resend must stay disabled for as long as the server asked.
                        resendAvailableAtMillis = limitedFor?.let { nowMillis() + it * 1000L }
                            ?: state.resendAvailableAtMillis,
                    )
                }
            } finally {
                _state.update { it.copy(busy = false) }
            }
        }
    }

    companion object {
        /** The server spaces resends 60, 120, 240, then 480 seconds apart. */
        const val RESEND_COOLDOWN_MILLIS = 60_000L

        fun factory(auth: PasswordAuthController): ViewModelProvider.Factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = AuthViewModel(auth) as T
        }
    }
}
