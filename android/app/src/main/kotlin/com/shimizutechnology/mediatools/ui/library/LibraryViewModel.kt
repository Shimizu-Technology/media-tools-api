package com.shimizutechnology.mediatools.ui.library

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.shimizutechnology.mediatools.api.LibraryItem
import com.shimizutechnology.mediatools.api.LibraryRepository
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class LibraryUiState(
    val items: List<LibraryItem> = emptyList(),
    val page: Int = 0,
    val totalPages: Int = 1,
    val totalItems: Int = 0,
    val isLoading: Boolean = false,
    val isLoadingMore: Boolean = false,
    val error: String? = null,
)

class LibraryViewModel(private val repository: LibraryRepository) : ViewModel() {
    private val _state = MutableStateFlow(LibraryUiState())
    val state = _state.asStateFlow()
    private var generation = 0L
    private var refreshJob: Job? = null
    private var loadMoreJob: Job? = null

    init { refresh() }

    fun refresh() {
        if (_state.value.isLoading) return
        generation += 1
        val requestGeneration = generation
        loadMoreJob?.cancel()
        refreshJob?.cancel()
        refreshJob = viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            runCatching { repository.listLibrary(page = 1) }
                .onSuccess { page ->
                    if (requestGeneration != generation) return@onSuccess
                    _state.value = LibraryUiState(
                        items = page.data,
                        page = page.page,
                        totalPages = page.totalPages.coerceAtLeast(1),
                        totalItems = page.totalItems,
                    )
                }
                .onFailure { error ->
                    if (requestGeneration != generation) return@onFailure
                    _state.update { it.copy(isLoading = false, error = error.message ?: "Could not load the library.") }
                }
        }
    }

    fun loadMore() {
        val current = _state.value
        if (current.isLoading || current.isLoadingMore || current.page >= current.totalPages) return
        val requestGeneration = generation
        loadMoreJob = viewModelScope.launch {
            _state.update { it.copy(isLoadingMore = true, error = null) }
            runCatching { repository.listLibrary(page = current.page + 1) }
                .onSuccess { page ->
                    if (requestGeneration != generation) return@onSuccess
                    val currentKeys = current.items.asSequence()
                        .map { "${it.itemType}:${it.id}" }
                        .toHashSet()
                    val boundaryShifted = page.totalItems != current.totalItems ||
                        page.data.any { "${it.itemType}:${it.id}" in currentKeys }
                    if (boundaryShifted) {
                        _state.update { it.copy(isLoadingMore = false) }
                        refresh()
                        return@onSuccess
                    }
                    _state.update { state ->
                        state.copy(
                            items = state.items + page.data,
                            page = page.page,
                            totalPages = page.totalPages.coerceAtLeast(1),
                            totalItems = page.totalItems,
                            isLoadingMore = false,
                        )
                    }
                }
                .onFailure { error ->
                    if (requestGeneration != generation) return@onFailure
                    _state.update { it.copy(isLoadingMore = false, error = error.message ?: "Could not load more items.") }
                }
        }
    }

    companion object {
        fun factory(repository: LibraryRepository): ViewModelProvider.Factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = LibraryViewModel(repository) as T
        }
    }
}
