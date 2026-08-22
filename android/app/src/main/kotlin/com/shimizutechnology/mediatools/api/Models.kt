package com.shimizutechnology.mediatools.api

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class PaginatedResponse<T>(
    val data: List<T>,
    val page: Int,
    @SerialName("per_page") val perPage: Int,
    @SerialName("total_items") val totalItems: Int,
    @SerialName("total_pages") val totalPages: Int,
)

@Serializable
data class LibraryItem(
    val id: String,
    @SerialName("item_type") val itemType: String,
    val title: String,
    val subtitle: String = "",
    val status: String,
    @SerialName("word_count") val wordCount: Int = 0,
    val duration: Double = 0.0,
    @SerialName("page_count") val pageCount: Int = 0,
    @SerialName("summary_status") val summaryStatus: String = "",
    val favorite: Boolean = false,
    val archived: Boolean = false,
    val tags: List<String> = emptyList(),
    @SerialName("created_at") val createdAt: String? = null,
)

@Serializable
data class TranscriptDetail(
    val id: String,
    val title: String = "Untitled video",
    val status: String,
    @SerialName("transcript_text") val transcriptText: String = "",
    @SerialName("word_count") val wordCount: Int = 0,
)

@Serializable
data class TranscriptSummary(
    val id: String,
    @SerialName("summary_text") val summaryText: String = "",
    val status: String = "",
)

@Serializable
data class AudioDetail(
    val id: String,
    val title: String? = null,
    @SerialName("original_name") val originalName: String? = null,
    val status: String,
    @SerialName("transcript_text") val transcriptText: String = "",
    @SerialName("formatted_transcript_text") val formattedTranscriptText: String = "",
    @SerialName("summary_text") val summaryText: String = "",
    @SerialName("word_count") val wordCount: Int = 0,
)

@Serializable
data class PdfDetail(
    val id: String,
    @SerialName("original_name") val originalName: String = "Untitled PDF",
    val status: String,
    @SerialName("text_content") val textContent: String = "",
    @SerialName("word_count") val wordCount: Int = 0,
)

data class LibraryDetail(
    val item: LibraryItem,
    val body: String,
    val summary: String = "",
    val summaryReportTarget: AIReportTarget? = null,
)

@Serializable
data class DeleteAccountRequest(val confirmation: String)

@Serializable
data class DeleteAccountResponse(
    val status: String,
    @SerialName("requested_at") val requestedAt: String,
    @SerialName("cleanup_after") val cleanupAfter: String,
)

@Serializable
data class AIReportRequest(
    @SerialName("target_type") val targetType: String,
    @SerialName("target_id") val targetId: String,
    val category: String,
    val details: String = "",
)

@Serializable
data class AIReportReceipt(
    val id: String,
    val status: String,
    @SerialName("already_reported") val alreadyReported: Boolean,
)

data class AIReportTarget(val type: String, val id: String)

@Serializable
data class APIErrorEnvelope(
    val error: String = "unknown",
    val message: String = "The request could not be completed.",
    val code: Int = 0,
)

class MediaToolsAPIException(val statusCode: Int, override val message: String) : Exception(message)
