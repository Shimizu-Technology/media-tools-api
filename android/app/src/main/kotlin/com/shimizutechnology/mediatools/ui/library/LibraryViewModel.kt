package com.shimizutechnology.mediatools.ui.library

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.shimizutechnology.mediatools.api.LibraryItem
import com.shimizutechnology.mediatools.api.MediaToolsApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class LibraryUiState(
    val items: List<LibraryItem> = emptyList(),
    val page: Int = 0,
    val totalPages: Int = 1,
    val isLoading: Boolean = false,
    val isLoadingMore: Boolean = false,
    val error: String? = null,
)

class LibraryViewModel(private val api: MediaToolsApi) : ViewModel() {
    private val _state = MutableStateFlow(LibraryUiState())
    val state = _state.asStateFlow()

    init { refresh() }

    fun refresh() {
        if (_state.value.isLoading) return
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            runCatching { api.listLibrary(page = 1) }
                .onSuccess { page ->
                    _state.value = LibraryUiState(
                        items = page.data,
                        page = page.page,
                        totalPages = page.totalPages.coerceAtLeast(1),
                    )
                }
                .onFailure { error ->
                    _state.update { it.copy(isLoading = false, error = error.message ?: "Could not load the library.") }
                }
        }
    }

    fun loadMore() {
        val current = _state.value
        if (current.isLoading || current.isLoadingMore || current.page >= current.totalPages) return
        viewModelScope.launch {
            _state.update { it.copy(isLoadingMore = true, error = null) }
            runCatching { api.listLibrary(page = current.page + 1) }
                .onSuccess { page ->
                    _state.update { state ->
                        val existingIds = state.items.asSequence().map { "${it.itemType}:${it.id}" }.toHashSet()
                        state.copy(
                            items = state.items + page.data.filter { existingIds.add("${it.itemType}:${it.id}") },
                            page = page.page,
                            totalPages = page.totalPages.coerceAtLeast(1),
                            isLoadingMore = false,
                        )
                    }
                }
                .onFailure { error ->
                    _state.update { it.copy(isLoadingMore = false, error = error.message ?: "Could not load more items.") }
                }
        }
    }

    companion object {
        fun factory(api: MediaToolsApi): ViewModelProvider.Factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = LibraryViewModel(api) as T
        }
    }
}
