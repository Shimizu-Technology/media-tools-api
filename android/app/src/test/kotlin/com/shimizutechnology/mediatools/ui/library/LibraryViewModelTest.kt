package com.shimizutechnology.mediatools.ui.library

import com.shimizutechnology.mediatools.api.LibraryItem
import com.shimizutechnology.mediatools.api.LibraryRepository
import com.shimizutechnology.mediatools.api.PaginatedResponse
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LibraryViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `refresh cancels and rejects an older pagination response`() = runTest(dispatcher) {
        val repository = DeferredRepository()
        val firstPage = repository.enqueue()
        val viewModel = LibraryViewModel(repository)
        runCurrent()
        firstPage.complete(page(1, 2, 40, listOf(item("old-1"))))
        advanceUntilIdle()

        val staleSecondPage = repository.enqueue()
        viewModel.loadMore()
        runCurrent()
        val refreshedPage = repository.enqueue()
        viewModel.refresh()
        runCurrent()

        staleSecondPage.complete(page(2, 2, 40, listOf(item("stale-2"))))
        refreshedPage.complete(page(1, 2, 40, listOf(item("new-1"))))
        advanceUntilIdle()

        assertEquals(listOf(1, 2, 1), repository.requestedPages)
        assertEquals(listOf("new-1"), viewModel.state.value.items.map { it.id })
        assertEquals(1, viewModel.state.value.page)
    }

    @Test
    fun `shifted page boundary triggers a clean page one reload`() = runTest(dispatcher) {
        val repository = DeferredRepository()
        val firstPage = repository.enqueue()
        val viewModel = LibraryViewModel(repository)
        runCurrent()
        firstPage.complete(page(1, 2, 40, listOf(item("a"), item("b"))))
        advanceUntilIdle()

        val shiftedSecondPage = repository.enqueue()
        val restartedFirstPage = repository.enqueue()
        viewModel.loadMore()
        runCurrent()
        shiftedSecondPage.complete(page(2, 3, 41, listOf(item("b"), item("c"))))
        runCurrent()
        restartedFirstPage.complete(page(1, 3, 41, listOf(item("new"), item("a"))))
        advanceUntilIdle()

        assertEquals(listOf(1, 2, 1), repository.requestedPages)
        assertEquals(listOf("new", "a"), viewModel.state.value.items.map { it.id })
        assertEquals(41, viewModel.state.value.totalItems)
    }
}

private class DeferredRepository : LibraryRepository {
    private val responses = ArrayDeque<CompletableDeferred<PaginatedResponse<LibraryItem>>>()
    val requestedPages = mutableListOf<Int>()

    fun enqueue(): CompletableDeferred<PaginatedResponse<LibraryItem>> =
        CompletableDeferred<PaginatedResponse<LibraryItem>>().also(responses::addLast)

    override suspend fun listLibrary(page: Int, perPage: Int): PaginatedResponse<LibraryItem> {
        requestedPages += page
        return responses.removeFirst().await()
    }
}

private fun page(
    page: Int,
    totalPages: Int,
    totalItems: Int,
    items: List<LibraryItem>,
) = PaginatedResponse(
    data = items,
    page = page,
    perPage = 20,
    totalItems = totalItems,
    totalPages = totalPages,
)

private fun item(id: String) = LibraryItem(
    id = id,
    itemType = "audio",
    title = id,
    status = "completed",
)
