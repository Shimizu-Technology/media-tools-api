package com.shimizutechnology.mediatools.api

import com.clerk.api.Clerk
import com.clerk.api.network.serialization.ClerkResult
import com.clerk.api.session.GetTokenOptions
import com.clerk.api.session.fetchToken
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

interface SessionTokenProvider {
    suspend fun token(expectedOwnerId: String, forceRefresh: Boolean = false): String
    fun currentOwnerId(): String?
}

class ClerkSessionTokenProvider : SessionTokenProvider {
    override suspend fun token(expectedOwnerId: String, forceRefresh: Boolean): String {
        val session = Clerk.session ?: throw MediaToolsAPIException(401, "Sign in to continue.")
        if (session.user?.id != expectedOwnerId) {
            throw MediaToolsAPIException(401, "The signed-in account changed. Try again.")
        }
        val token = when (val result = session.fetchToken(GetTokenOptions(skipCache = forceRefresh))) {
            is ClerkResult.Success -> result.value.jwt
            is ClerkResult.Failure -> throw MediaToolsAPIException(
                401,
                if (Clerk.session == null) "Sign in to continue." else "Your sign-in session could not be refreshed.",
            )
        }
        if (Clerk.session?.id != session.id || Clerk.user?.id != expectedOwnerId) {
            throw MediaToolsAPIException(401, "The signed-in account changed. Try again.")
        }
        return token
    }

    override fun currentOwnerId(): String? = Clerk.user?.id
}

interface LibraryRepository {
    suspend fun listLibrary(page: Int, perPage: Int = 20): PaginatedResponse<LibraryItem>
}

class MediaToolsApi(
    private val baseUrl: String,
    private val tokenProvider: SessionTokenProvider,
    private val client: OkHttpClient = OkHttpClient(),
    private val json: Json = Json { ignoreUnknownKeys = true; explicitNulls = false },
) : LibraryRepository {
    override suspend fun listLibrary(page: Int, perPage: Int): PaginatedResponse<LibraryItem> =
        get("/library/items?page=${page.coerceAtLeast(1)}&per_page=${perPage.coerceIn(1, 100)}&sort_dir=desc")

    suspend fun loadDetail(itemType: String, itemId: String): LibraryDetail = when (itemType) {
        "youtube", "transcript" -> {
            val detail: TranscriptDetail = get("/transcripts/$itemId")
            val summaries: List<TranscriptSummary> = get("/transcripts/$itemId/summaries")
            val completed = summaries.firstOrNull { it.status == "completed" && it.summaryText.isNotBlank() }
            LibraryDetail(
                item = LibraryItem(
                    id = detail.id,
                    itemType = "youtube",
                    title = detail.title,
                    status = detail.status,
                    wordCount = detail.wordCount,
                ),
                body = detail.transcriptText,
                summary = completed?.summaryText.orEmpty(),
                summaryReportTarget = completed?.let { AIReportTarget("transcript_summary", it.id) },
            )
        }
        "audio" -> {
            val detail: AudioDetail = get("/audio/transcriptions/$itemId")
            LibraryDetail(
                item = LibraryItem(
                    id = detail.id,
                    itemType = "audio",
                    title = detail.title ?: detail.originalName ?: "Untitled recording",
                    status = detail.status,
                    wordCount = detail.wordCount,
                ),
                body = detail.formattedTranscriptText.ifBlank { detail.transcriptText },
                summary = detail.summaryText,
                summaryReportTarget = detail.summaryText.takeIf(String::isNotBlank)
                    ?.let { AIReportTarget("audio_summary", detail.id) },
            )
        }
        "pdf" -> {
            val detail: PdfDetail = get("/pdf/extractions/$itemId")
            LibraryDetail(
                item = LibraryItem(
                    id = detail.id,
                    itemType = "pdf",
                    title = detail.originalName,
                    status = detail.status,
                    wordCount = detail.wordCount,
                ),
                body = detail.textContent,
            )
        }
        else -> throw MediaToolsAPIException(400, "Unsupported library item type.")
    }

    suspend fun reportAIOutput(target: AIReportTarget, category: String, details: String): AIReportReceipt =
        post(
            "/ai-content-reports",
            json.encodeToString(AIReportRequest(target.type, target.id, category, details.trim())),
        )

    suspend fun deleteAccount(): DeleteAccountResponse =
        delete("/account", json.encodeToString(DeleteAccountRequest("DELETE")))

    private suspend inline fun <reified T> get(path: String): T =
        execute(path = path, method = "GET", body = null)

    private suspend inline fun <reified T> post(path: String, body: String): T =
        execute(path = path, method = "POST", body = body)

    private suspend inline fun <reified T> delete(path: String, body: String): T =
        execute(path = path, method = "DELETE", body = body)

    private suspend inline fun <reified T> execute(path: String, method: String, body: String?): T {
        val expectedOwnerId = tokenProvider.currentOwnerId()
            ?: throw MediaToolsAPIException(401, "Sign in to continue.")
        val first = executeOnce(path, method, body, expectedOwnerId, forceRefresh = false)
        val response = if (first.code == 401) {
            first.close()
            executeOnce(path, method, body, expectedOwnerId, forceRefresh = true)
        } else {
            first
        }

        response.use {
            if (tokenProvider.currentOwnerId() != expectedOwnerId) {
                throw MediaToolsAPIException(401, "The signed-in account changed. Try again.")
            }
            val payload = it.body.string()
            if (!it.isSuccessful) {
                val serverError = runCatching { json.decodeFromString<APIErrorEnvelope>(payload) }.getOrNull()
                throw MediaToolsAPIException(it.code, serverError?.message ?: "Request failed (${it.code}).")
            }
            return try {
                json.decodeFromString<T>(payload)
            } catch (error: Exception) {
                throw IOException("Media Tools returned an unreadable response.", error)
            }
        }
    }

    @PublishedApi
    internal suspend fun executeOnce(
        path: String,
        method: String,
        body: String?,
        expectedOwnerId: String,
        forceRefresh: Boolean,
    ) = withContext(Dispatchers.IO) {
        val requestBody = body?.toRequestBody(JSON_MEDIA_TYPE)
        val request = Request.Builder()
            .url(baseUrl.trimEnd('/') + path)
            .header("Accept", "application/json")
            .header("Authorization", "Bearer ${tokenProvider.token(expectedOwnerId, forceRefresh)}")
            .method(method, requestBody)
            .build()
        client.newCall(request).execute()
    }

    private companion object {
        val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()
    }
}
