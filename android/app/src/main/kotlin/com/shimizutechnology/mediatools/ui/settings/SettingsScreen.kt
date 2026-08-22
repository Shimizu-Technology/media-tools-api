package com.shimizutechnology.mediatools.ui.settings

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.automirrored.outlined.Logout
import androidx.compose.material.icons.outlined.DeleteForever
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Policy
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.clerk.api.Clerk
import com.clerk.api.network.serialization.ClerkResult
import com.shimizutechnology.mediatools.AppLinks
import com.shimizutechnology.mediatools.api.MediaToolsApi
import com.shimizutechnology.mediatools.consent.AIProcessingConsentStore
import kotlinx.coroutines.launch

@Composable
fun SettingsScreen(api: MediaToolsApi, consentStore: AIProcessingConsentStore, ownerId: String) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var hasAIConsent by remember(ownerId) { mutableStateOf(consentStore.hasConsent(ownerId)) }
    var showAIDisclosure by remember { mutableStateOf(false) }
    var showDelete by remember { mutableStateOf(false) }
    var accountMessage by remember { mutableStateOf<String?>(null) }
    var deletionMessage by remember { mutableStateOf<String?>(null) }

    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Text("Settings", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)

        SettingsSection("AI processing") {
            Text(
                if (hasAIConsent) "Allowed for this account on this device" else "Permission has not been granted",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                "Before an AI feature sends audio, text, or prompts to a third-party provider, Media Tools requires explicit permission.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (hasAIConsent) {
                OutlinedButton(
                    onClick = {
                        consentStore.revoke(ownerId)
                        hasAIConsent = false
                    },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Revoke AI permission") }
            } else {
                Button(onClick = { showAIDisclosure = true }, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Outlined.Psychology, contentDescription = null)
                    Text("Review AI processing", Modifier.padding(start = 8.dp))
                }
            }
        }

        SettingsSection("Recording responsibility") {
            Text(
                "Only record or upload content when you have the rights and permission required where the recording occurs. Recording consent laws vary by location.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        SettingsSection("Help and legal") {
            SettingsLink(Icons.Outlined.Policy, "Privacy policy") { openUrl(context, AppLinks.PRIVACY) }
            SettingsLink(Icons.Outlined.Description, "Terms of use") { openUrl(context, AppLinks.TERMS) }
            SettingsLink(Icons.AutoMirrored.Outlined.HelpOutline, "Support") { openUrl(context, AppLinks.SUPPORT) }
            SettingsLink(Icons.Outlined.Public, "Delete account on the web") { openUrl(context, AppLinks.DELETE_ACCOUNT) }
        }

        SettingsSection("Account") {
            OutlinedButton(
                onClick = {
                    scope.launch {
                        if (Clerk.auth.signOut() is ClerkResult.Failure) {
                            accountMessage = "Media Tools could not sign out. Check your connection and try again."
                        }
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.AutoMirrored.Outlined.Logout, contentDescription = null)
                Text("Sign out", Modifier.padding(start = 8.dp))
            }
            accountMessage?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }

        SettingsSection("Danger zone") {
            Text(
                "Permanently removes your recordings, transcripts, PDFs, chats, collections, developer keys, and account. This cannot be undone.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedButton(onClick = { showDelete = true }, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Outlined.DeleteForever, contentDescription = null, tint = MaterialTheme.colorScheme.error)
                Text("Delete account and data", Modifier.padding(start = 8.dp), color = MaterialTheme.colorScheme.error)
            }
            deletionMessage?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }

    if (showAIDisclosure) {
        AIProcessingDisclosure(
            onAllow = {
                consentStore.allow(ownerId)
                hasAIConsent = true
                showAIDisclosure = false
            },
            onDecline = { showAIDisclosure = false },
            onOpenDetails = { openUrl(context, AppLinks.AI_PRIVACY) },
        )
    }

    if (showDelete) {
        DeleteAccountDialog(
            api = api,
            onDismiss = { showDelete = false },
            onDeleted = {
                consentStore.revoke(ownerId)
                hasAIConsent = false
                showDelete = false
                scope.launch {
                    if (Clerk.auth.signOut() is ClerkResult.Failure) {
                        deletionMessage = "Your account deletion is underway, but this device could not finish signing out. Close and reopen Media Tools."
                    }
                }
            },
            onError = { deletionMessage = it },
        )
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title.uppercase(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
        content()
    }
}

@Composable
private fun SettingsLink(icon: ImageVector, label: String, action: () -> Unit) {
    TextButton(onClick = action, modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null)
            Text(label, Modifier.padding(start = 12.dp).weight(1f))
        }
    }
}

@Composable
private fun AIProcessingDisclosure(onAllow: () -> Unit, onDecline: () -> Unit, onOpenDetails: () -> Unit) {
    AlertDialog(
        onDismissRequest = {},
        title = { Text("Allow third-party AI processing?") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Media Tools only sends content when you choose an AI feature. Permission applies to this account on this Android device.")
                Text("OpenAI receives audio for transcription and may process text if the primary AI route is unavailable. API content is not used to train OpenAI models by default.")
                Text("OpenRouter and the selected model provider receive transcript or document text and chat prompts for formatting, summaries, citations, and answers. Media Tools requires zero-data-retention providers.")
                Text("You can revoke permission for future requests in Settings. Processing you already started may finish.")
                TextButton(onClick = onOpenDetails) { Text("Read AI and privacy details") }
            }
        },
        confirmButton = { Button(onClick = onAllow) { Text("Allow AI processing") } },
        dismissButton = { TextButton(onClick = onDecline) { Text("Not now") } },
    )
}

@Composable
private fun DeleteAccountDialog(
    api: MediaToolsApi,
    onDismiss: () -> Unit,
    onDeleted: () -> Unit,
    onError: (String) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var confirmation by remember { mutableStateOf("") }
    var submitting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = { if (!submitting) onDismiss() },
        title = { Text("Permanently delete your account?") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Server data is purged immediately. Secure provider cleanup continues in the background. This cannot be undone.")
                OutlinedTextField(
                    value = confirmation,
                    onValueChange = { confirmation = it.uppercase().take(6) },
                    label = { Text("Type DELETE to confirm") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            Button(
                enabled = confirmation == "DELETE" && !submitting,
                onClick = {
                    submitting = true
                    error = null
                    scope.launch {
                        runCatching { api.deleteAccount() }
                            .onSuccess { onDeleted() }
                            .onFailure {
                                val message = it.message ?: "Account deletion could not be started."
                                error = message
                                onError(message)
                            }
                        submitting = false
                    }
                },
            ) { Text(if (submitting) "Deleting…" else "Permanently delete") }
        },
        dismissButton = { TextButton(enabled = !submitting, onClick = onDismiss) { Text("Cancel") } },
    )
}

private fun openUrl(context: android.content.Context, url: String) {
    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
}
