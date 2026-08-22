package com.shimizutechnology.mediatools

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaToolsApplicationTest {
    @Test
    fun `placeholder never initializes Clerk`() {
        assertFalse(MediaToolsApplication.isClerkConfigured(""))
        assertFalse(MediaToolsApplication.isClerkConfigured("pk_test_placeholder_for_ci"))
        assertFalse(MediaToolsApplication.isClerkConfigured("secret_value"))
        assertTrue(MediaToolsApplication.isClerkConfigured("pk_test_valid-development-value"))
        assertTrue(MediaToolsApplication.isClerkConfigured("pk_live_valid-production-value"))
    }
}
