package com.shimizutechnology.mediatools.api

import java.text.Normalizer
import java.util.Locale
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** What `/health` says this server accepts. Sign-up stays hidden unless it says so. */
@Serializable
data class AuthAvailability(
    @SerialName("signup_enabled") val signupEnabled: Boolean = false,
    @SerialName("password_auth_enabled") val passwordAuthEnabled: Boolean = true,
)

@Serializable
data class PasswordStatus(val configured: Boolean = false)

/**
 * Email and password sign-in, sign-up with a verification code, password reset, and
 * password change, written against docs/AUTH_API.md.
 *
 * Rules this class enforces for every caller:
 * - Initiation (sign-up, forgot password) returns the same result for any address, so
 *   nothing here, or in the UI built on it, can reveal whether an account exists.
 * - A code or password is never persisted. Password sign-in saves only its successor
 *   refresh credential, so an ambiguous response can be retried into the same session.
 * - Codes and passwords never appear in an exception message.
 */
class PasswordAuthController(
    private val store: DeviceSessionStore,
    private val transport: DeviceSessionTransport,
    private val deviceSession: DeviceSessionController,
    private val deviceName: () -> String,
    private val randomRefreshToken: () -> String = ::newDeviceRefreshToken,
    private val json: Json = authJson,
) {
    private val mutex = Mutex()

    /** Throws on any failure; callers treat that as "sign-up not offered" and keep sign-in. */
    suspend fun availability(): AuthAvailability {
        val response = transport.send("/health", null, method = "GET")
        if (response.status !in 200..299) throw response.toApiException("Could not check sign-in availability", json)
        return runCatching { json.decodeFromString<AuthAvailability>(response.body) }.getOrElse {
            throw MediaToolsAPIException(502, "Media Tools returned an unreadable response.")
        }
    }

    suspend fun signIn(email: String, password: String): DeviceSessionPair = mutex.withLock {
        if (deviceSession.currentOwnerId() != null) {
            throw MediaToolsAPIException(409, "Sign out of the current account before signing in again.")
        }
        val normalized = normalizeEmail(email)
        if (normalized.isEmpty() || password.isEmpty()) {
            throw MediaToolsAPIException(400, "Enter your email and password.", "invalid_request")
        }
        var pending = store.loadPendingPasswordLogin()
        if (pending == null || pending.email != normalized) {
            // A different address never reuses the previous address's successor.
            pending = PendingPasswordLogin(normalized, randomRefreshToken(), deviceName().trim().take(80))
            store.savePendingPasswordLogin(pending)
        }
        val response = transport.send(
            "/auth/password/login",
            json.encodeToString(
                PasswordLoginRequest(
                    email = pending.email,
                    password = password,
                    clientType = "android",
                    deviceName = pending.deviceName,
                    nextRefreshToken = pending.nextRefreshToken,
                )
            ),
        )
        // The server rejects a 400 successor permanently. Anything else, including 401, 429,
        // 503, and a lost response, keeps the journal: no session exists for a rejected
        // password, and a lost 201 is recovered by sending the same successor again.
        if (response.status == 400) store.clearPendingPasswordLogin()
        if (response.status !in 200..299) throw response.toApiException("Sign-in unavailable", json)
        val pair = response.decode<DeviceSessionPair>()
        if (pair.refreshToken != pending.nextRefreshToken) {
            throw MediaToolsAPIException(502, "Media Tools returned an invalid device session.")
        }
        deviceSession.installSession(pair, pending.nextRefreshToken)
        pair
    }

    /** Starts sign-up or resends its code. Succeeds identically for every address. */
    suspend fun startSignup(email: String, name: String? = null) {
        val body = json.encodeToString(SignupRequest(requireEmail(email), name?.trim()?.takeIf(String::isNotEmpty)))
        requireAccepted(transport.send("/auth/signup", body), "Sign-up unavailable")
    }

    /** Creates the verified account and its password. Does not sign in. */
    suspend fun completeSignup(email: String, code: String, password: String) {
        val body = json.encodeToString(CodePasswordRequest(requireEmail(email), requireCode(code), requirePassword(password)))
        requireOk(transport.send("/auth/signup/verify", body), "Could not verify your email")
    }

    suspend fun startPasswordReset(email: String) {
        val body = json.encodeToString(EmailRequest(requireEmail(email)))
        requireAccepted(transport.send("/auth/password/forgot", body), "Password reset unavailable")
    }

    /** Sets a new password, verifies the address, and signs this account out everywhere. */
    suspend fun completePasswordReset(email: String, code: String, password: String) {
        val body = json.encodeToString(CodePasswordRequest(requireEmail(email), requireCode(code), requirePassword(password)))
        requireOk(transport.send("/auth/password/reset", body), "Could not reset your password")
    }

    suspend fun passwordConfigured(): Boolean {
        val owner = requireOwner()
        val response = transport.sendAuthenticated(deviceSession, owner, "/auth/password", null, "GET")
        if (response.status !in 200..299) throw response.toApiException("Could not check your password", json)
        return response.decode<PasswordStatus>().configured
    }

    /**
     * [current] is required when the account already has a password. The server keeps this
     * session signed in and revokes the account's other sessions.
     */
    suspend fun changePassword(current: String?, new: String) {
        val owner = requireOwner()
        val body = json.encodeToString(
            ChangePasswordRequest(password = requirePassword(new), currentPassword = current?.takeIf(String::isNotEmpty))
        )
        val response = transport.sendAuthenticated(deviceSession, owner, "/auth/password", body)
        if (response.status !in 200..299) throw response.toApiException("Could not change your password", json)
    }

    private fun requireOwner(): String = deviceSession.currentOwnerId()
        ?: throw MediaToolsAPIException(401, "Sign in to continue.")

    private fun requireAccepted(response: SessionResponse, fallback: String) {
        if (response.status != 202) throw response.toApiException(fallback, json)
    }

    private fun requireOk(response: SessionResponse, fallback: String) {
        if (response.status !in 200..299) throw response.toApiException(fallback, json)
    }

    private inline fun <reified T> SessionResponse.decode(): T =
        runCatching { json.decodeFromString<T>(body) }.getOrElse {
            throw MediaToolsAPIException(502, "Media Tools returned an unreadable response.")
        }

    @Serializable
    private data class PasswordLoginRequest(
        val email: String,
        val password: String,
        @SerialName("client_type") val clientType: String,
        @SerialName("device_name") val deviceName: String,
        @SerialName("next_refresh_token") val nextRefreshToken: String,
    )

    @Serializable private data class EmailRequest(val email: String)
    @Serializable private data class SignupRequest(val email: String, val name: String? = null)
    @Serializable private data class CodePasswordRequest(val email: String, val code: String, val password: String)
    @Serializable
    private data class ChangePasswordRequest(
        val password: String,
        @SerialName("current_password") val currentPassword: String? = null,
    )
}

/** Matches the server's login normalization: trimmed, NFC, lower case. */
fun normalizeEmail(email: String): String =
    Normalizer.normalize(email.trim(), Normalizer.Form.NFC).lowercase(Locale.ROOT)

/** A deliberately loose check: the server is the authority, this only catches typos early. */
fun looksLikeEmail(email: String): Boolean {
    val value = normalizeEmail(email)
    val at = value.indexOf('@')
    return value.length <= 255 && at > 0 && at == value.lastIndexOf('@') &&
        value.substring(at + 1).let { it.contains('.') && !it.startsWith('.') && !it.endsWith('.') } &&
        value.none(Char::isWhitespace)
}

/** The server's rule: 12 to 128 Unicode characters after NFC normalization. */
fun isAcceptablePassword(password: String): Boolean =
    Normalizer.normalize(password, Normalizer.Form.NFC).let { it.codePointCount(0, it.length) in 12..128 }

fun normalizeCode(code: String): String = code.filter(Char::isDigit)

private fun requireEmail(email: String): String {
    if (!looksLikeEmail(email)) throw MediaToolsAPIException(400, "Enter a valid email address.", "invalid_request")
    return normalizeEmail(email)
}

private fun requireCode(code: String): String {
    val digits = normalizeCode(code)
    if (digits.length != 6) throw MediaToolsAPIException(400, "Enter the 6-digit code from your email.", "invalid_code")
    return digits
}

private fun requirePassword(password: String): String {
    if (!isAcceptablePassword(password)) {
        throw MediaToolsAPIException(400, "Use a password of 12 to 128 characters.", "weak_password")
    }
    return password
}
