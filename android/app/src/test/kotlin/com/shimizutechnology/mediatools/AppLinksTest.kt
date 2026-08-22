package com.shimizutechnology.mediatools

import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AppLinksTest {
    @Test
    fun `policy support and web deletion links use the public app origin`() {
        listOf(AppLinks.PRIVACY, AppLinks.AI_PRIVACY, AppLinks.TERMS, AppLinks.SUPPORT, AppLinks.DELETE_ACCOUNT)
            .forEach { value ->
                val uri = URI(value)
                assertEquals("https", uri.scheme)
                assertEquals("media-tools-gu.netlify.app", uri.host)
                assertTrue(uri.path.isNotBlank())
            }
    }
}
