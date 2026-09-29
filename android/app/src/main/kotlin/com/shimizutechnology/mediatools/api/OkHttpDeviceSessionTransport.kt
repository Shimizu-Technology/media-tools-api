package com.shimizutechnology.mediatools.api

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

class OkHttpDeviceSessionTransport(
    private val baseUrl: String,
    private val client: OkHttpClient = OkHttpClient(),
) : DeviceSessionTransport {
    override suspend fun send(path: String, body: String?, bearer: String?, method: String): SessionResponse =
        withContext(Dispatchers.IO) {
            val request = Request.Builder()
                .url(baseUrl.trimEnd('/') + path)
                .header("Accept", "application/json")
                .apply { if (bearer != null) header("Authorization", "Bearer $bearer") }
                .method(method, body?.toRequestBody(JSON_MEDIA_TYPE))
                .build()
            client.newCall(request).execute().use {
                SessionResponse(it.code, it.body.string())
            }
        }

    private companion object {
        val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()
    }
}
