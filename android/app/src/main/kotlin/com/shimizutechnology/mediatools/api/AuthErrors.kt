package com.shimizutechnology.mediatools.api

import java.io.IOException
import kotlinx.serialization.json.Json

/** The generic body every email-proof initiation returns, whether or not an account exists. */
const val GENERIC_EMAIL_RECEIPT = "If this request is eligible, an email will arrive shortly"

internal val authJson = Json { ignoreUnknownKeys = true; explicitNulls = false }

/** Converts a non-2xx response into an exception carrying the server's stable error code. */
internal fun SessionResponse.toApiException(fallback: String, json: Json = authJson): MediaToolsAPIException {
    val envelope = runCatching { json.decodeFromString<APIErrorEnvelope>(body) }.getOrNull()
    return MediaToolsAPIException(
        statusCode = status,
        message = envelope?.message ?: "$fallback ($status).",
        errorCode = envelope?.error?.takeUnless { it == "unknown" },
        retryAfterSeconds = retryAfterSeconds,
    )
}

/**
 * A network failure (IOException) or an overloaded server says nothing about the session,
 * so it must never be treated as a sign-out.
 */
fun Throwable.isTransientAuthFailure(): Boolean =
    this is IOException || (this is MediaToolsAPIException && (statusCode == 429 || statusCode >= 500 ||
        errorCode == "session_refresh_in_progress"))

/** Plain-language copy for the auth screens. Never includes a code, password, or address. */
fun Throwable.authFailureMessage(): String {
    if (this is IOException) return "Could not reach Media Tools. Check your connection and try again."
    if (this !is MediaToolsAPIException) return message ?: "Something went wrong. Try again."
    return when (errorCode) {
        "invalid_credentials" -> "Email or password is incorrect."
        "current_password_required" -> "Your current password is incorrect."
        "rate_limit_exceeded" -> "Too many attempts. Try again ${waitPhrase(retryAfterSeconds)}."
        "invalid_code" -> "That code is wrong or has expired. Check it, or request a new one."
        "weak_password" -> "Use a password of 12 to 128 characters."
        "password_compromised" -> "That password appears in known data breaches. Choose a different one."
        "signup_disabled" -> "Sign-up is not open yet."
        "email_verification_required" ->
            "Verify your email first: sign out, then use Forgot password with your account email."
        "credential_changed" -> "Your password changed somewhere else. Sign in again."
        "session_refresh_in_progress" -> "Your session is syncing. Try again in a moment."
        "authentication_unavailable", "usage_unavailable" -> "Media Tools is unavailable right now. Try again shortly."
        else -> if (statusCode >= 500) "Media Tools is unavailable right now. Try again shortly." else message
    }
}

private fun waitPhrase(seconds: Int?): String = when {
    seconds == null || seconds <= 0 -> "in a few minutes"
    seconds < 90 -> "in $seconds seconds"
    else -> "in about ${(seconds + 59) / 60} minutes"
}

/**
 * Sends an authenticated request, refreshing the access credential once if it is rejected.
 * A 401 that proves the *password* was wrong is not an expired credential, so it is never
 * replayed: a replay would count a second failure against the account.
 */
internal suspend fun DeviceSessionTransport.sendAuthenticated(
    deviceSession: DeviceSessionController,
    owner: String,
    path: String,
    body: String?,
    method: String = "POST",
): SessionResponse {
    val firstToken = deviceSession.token(owner)
    val first = send(path, body, bearer = firstToken, method = method)
    if (first.status != 401) return first
    val code = runCatching { authJson.decodeFromString<APIErrorEnvelope>(first.body).error }.getOrNull()
    if (code == "current_password_required" || code == "invalid_credentials") return first
    val replacement = deviceSession.refreshAfterRejectedToken(owner, firstToken)
    return send(path, body, bearer = replacement, method = method)
}
