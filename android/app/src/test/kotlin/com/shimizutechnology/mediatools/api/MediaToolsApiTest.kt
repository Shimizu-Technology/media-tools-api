package com.shimizutechnology.mediatools.api

import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class MediaToolsApiTest {
    private lateinit var server: MockWebServer
    private lateinit var tokens: RecordingTokenProvider
    private lateinit var api: MediaToolsApi

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        tokens = RecordingTokenProvider()
        api = MediaToolsApi(server.url("/api/v1").toString().trimEnd('/'), tokens)
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun `library request is authenticated and decodes account scoped page`() = runTest {
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """{"data":[{"id":"a1","item_type":"audio","title":"Interview","status":"completed","tags":[]}],"page":1,"per_page":20,"total_items":1,"total_pages":1}"""
            )
        )

        val page = api.listLibrary(page = 1)

        assertEquals("Interview", page.data.single().title)
        assertEquals(1, page.totalItems)
        val request = server.takeRequest()
        assertEquals("Bearer cached-token", request.getHeader("Authorization"))
        assertEquals("/api/v1/library/items?page=1&per_page=20&sort_dir=desc", request.path)
    }

    @Test
    fun `one rejected token is refreshed before account deletion retry`() = runTest {
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"message":"expired"}"""))
        server.enqueue(
            MockResponse().setResponseCode(202).setBody(
                """{"status":"pending","requested_at":"2026-08-22T12:00:00Z","cleanup_after":"2026-08-22T12:05:00Z"}"""
            )
        )

        val result = api.deleteAccount()

        assertEquals("pending", result.status)
        assertEquals(listOf(false, true), tokens.refreshCalls)
        val first = server.takeRequest()
        val second = server.takeRequest()
        assertEquals("DELETE", first.method)
        assertEquals("{\"confirmation\":\"DELETE\"}", first.body.readUtf8())
        assertEquals("Bearer refreshed-token", second.getHeader("Authorization"))
    }

    @Test
    fun `server error message is preserved`() = runTest {
        server.enqueue(
            MockResponse().setResponseCode(503).setBody(
                """{"error":"account_deletion_unavailable","message":"Account deletion is temporarily unavailable.","code":503}"""
            )
        )

        val error = runCatching { api.deleteAccount() }.exceptionOrNull()

        assertTrue(error is MediaToolsAPIException)
        assertEquals("Account deletion is temporarily unavailable.", error?.message)
    }

    @Test
    fun `account switch prevents a rejected request from retrying as another user`() = runTest {
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"message":"expired"}"""))
        val switchingTokens = SwitchingTokenProvider()
        val switchingApi = MediaToolsApi(server.url("/api/v1").toString().trimEnd('/'), switchingTokens)

        val error = runCatching { switchingApi.deleteAccount() }.exceptionOrNull()

        assertTrue(error is MediaToolsAPIException)
        assertEquals("The signed-in account changed. Try again.", error?.message)
        assertEquals(1, server.requestCount)
    }
}

private class RecordingTokenProvider : SessionTokenProvider {
    val refreshCalls = mutableListOf<Boolean>()
    override suspend fun token(expectedOwnerId: String, forceRefresh: Boolean): String {
        require(expectedOwnerId == "user_test")
        refreshCalls += forceRefresh
        return if (forceRefresh) "refreshed-token" else "cached-token"
    }
    override fun currentOwnerId(): String = "user_test"
}

private class SwitchingTokenProvider : SessionTokenProvider {
    private var ownerId = "user_one"
    override suspend fun token(expectedOwnerId: String, forceRefresh: Boolean): String {
        if (ownerId != expectedOwnerId) {
            throw MediaToolsAPIException(401, "The signed-in account changed. Try again.")
        }
        if (!forceRefresh) ownerId = "user_two"
        return "token"
    }
    override fun currentOwnerId(): String = ownerId
}
