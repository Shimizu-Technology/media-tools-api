package com.shimizutechnology.mediatools.ui.settings

import android.content.Intent
import android.net.Uri
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.os.Build
import android.os.PersistableBundle
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.automirrored.outlined.Logout
import androidx.compose.material.icons.outlined.DeleteForever
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Policy
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.shimizutechnology.mediatools.AppLinks
import com.shimizutechnology.mediatools.api.MediaToolsApi
import com.shimizutechnology.mediatools.api.PasswordAuthController
import com.shimizutechnology.mediatools.api.RecoveryAuthController
import com.shimizutechnology.mediatools.api.RecoveryCodeStatus
import com.shimizutechnology.mediatools.api.authFailureMessage
import com.shimizutechnology.mediatools.api.isAcceptablePassword
import com.shimizutechnology.mediatools.consent.AIProcessingConsentStore
import kotlinx.coroutines.launch

@Composable
fun SettingsScreen(
    api: MediaToolsApi,
    consentStore: AIProcessingConsentStore,
    ownerId: String,
    recoveryAuth: RecoveryAuthController,
    passwordAuth: PasswordAuthController,
    onSignOut: suspend () -> Unit,
    onDeleted: suspend () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var hasAIConsent by remember(ownerId) { mutableStateOf(consentStore.hasConsent(ownerId)) }
    var showAIDisclosure by remember { mutableStateOf(false) }
    var showDelete by remember { mutableStateOf(false) }
    var accountMessage by remember { mutableStateOf<String?>(null) }
    var deletionMessage by remember { mutableStateOf<String?>(null) }
    var recoveryStatus by remember(ownerId) { mutableStateOf<RecoveryCodeStatus?>(null) }
    var recoveryError by remember(ownerId) { mutableStateOf<String?>(null) }
    var recoveryNotice by remember(ownerId) { mutableStateOf<String?>(null) }
    var loadingRecovery by remember(ownerId) { mutableStateOf(false) }
    var startingRecovery by remember(ownerId) { mutableStateOf(false) }
    var confirmingRecovery by remember(ownerId) { mutableStateOf(false) }
    var showReplaceRecovery by remember { mutableStateOf(false) }
    var recoveryCodes by remember(ownerId) { mutableStateOf<List<String>>(emptyList()) }
    // Null until the server answers, so deletion never guesses whether a password is needed.
    var passwordConfigured by remember(ownerId) { mutableStateOf<Boolean?>(null) }
    var showChangePassword by remember { mutableStateOf(false) }
    var passwordNotice by remember(ownerId) { mutableStateOf<String?>(null) }

    suspend fun loadRecoveryStatus() {
        val controller = recoveryAuth
        loadingRecovery = true
        runCatching { controller.status() }
            .onSuccess { recoveryStatus = it; recoveryError = null }
            .onFailure { recoveryError = it.message ?: "Could not check recovery codes." }
        loadingRecovery = false
    }

    fun beginRecoveryRotation() {
        val controller = recoveryAuth
        startingRecovery = true
        recoveryError = null
        recoveryNotice = null
        scope.launch {
            runCatching { controller.beginRotation() }
                .onSuccess { recoveryCodes = it }
                .onFailure { recoveryError = it.message ?: "Could not create recovery codes." }
            startingRecovery = false
        }
    }

    LaunchedEffect(recoveryAuth, ownerId) { loadRecoveryStatus() }
    LaunchedEffect(passwordAuth, ownerId) {
        passwordConfigured = runCatching { passwordAuth.passwordConfigured() }.getOrNull()
    }

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
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                ) { Text("Revoke AI permission") }
            } else {
                Button(onClick = { showAIDisclosure = true }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
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

        SettingsSection("Password") {
            Text(
                when (passwordConfigured) {
                    true -> "Changing your password signs your other devices out."
                    false -> "No password is set for this account yet."
                    null -> "Password status is unavailable."
                },
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedButton(
                enabled = passwordConfigured != null,
                onClick = { passwordNotice = null; showChangePassword = true },
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
            ) {
                Icon(Icons.Outlined.Lock, contentDescription = null)
                Text(if (passwordConfigured == false) "Set a password" else "Change password", Modifier.padding(start = 8.dp))
            }
            passwordNotice?.let { Text(it, color = MaterialTheme.colorScheme.primary) }
        }

        SettingsSection("Account recovery") {
            Text(
                when {
                    loadingRecovery -> "Checking recovery codes…"
                    recoveryStatus == null -> "Recovery-code status is unavailable."
                    recoveryStatus!!.remaining == 0 -> "No saved recovery codes"
                    else -> "${recoveryStatus!!.remaining} one-time recovery codes remaining"
                },
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                "Recovery codes let you sign in when your usual sign-in is unavailable. Each code works once.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Button(
                enabled = !startingRecovery && !loadingRecovery,
                onClick = {
                    if ((recoveryStatus?.remaining ?: 0) > 0) showReplaceRecovery = true
                    else beginRecoveryRotation()
                },
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
            ) {
                if (startingRecovery) CircularProgressIndicator(Modifier.size(18.dp).padding(end = 4.dp))
                Text(if ((recoveryStatus?.remaining ?: 0) > 0) "Replace recovery codes" else "Create recovery codes")
            }
            recoveryNotice?.let { Text(it, color = MaterialTheme.colorScheme.primary) }
            recoveryError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
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
                        try {
                            onSignOut()
                        } catch (_: Exception) {
                            accountMessage = "Media Tools could not sign out. Check your connection and try again."
                        }
                    }
                },
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
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
            OutlinedButton(onClick = { showDelete = true }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
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

    if (showChangePassword) {
        ChangePasswordDialog(
            passwordAuth = passwordAuth,
            hasPassword = passwordConfigured == true,
            onDismiss = { showChangePassword = false },
            onChanged = {
                passwordConfigured = true
                passwordNotice = "Password updated."
                showChangePassword = false
            },
        )
    }

    if (showDelete) {
        DeleteAccountDialog(
            api = api,
            passwordConfigured = passwordConfigured,
            onDismiss = { showDelete = false },
            onDeleted = {
                consentStore.revoke(ownerId)
                hasAIConsent = false
                showDelete = false
                scope.launch {
                    try {
                        onDeleted()
                    } catch (_: Exception) {
                        deletionMessage = "Your account deletion is underway, but this device could not finish signing out. Close and reopen Media Tools."
                    }
                }
            },
            onError = { deletionMessage = it },
        )
    }


    if (showReplaceRecovery) {
        AlertDialog(
            onDismissRequest = { showReplaceRecovery = false },
            title = { Text("Replace recovery codes?") },
            text = { Text("Your current codes keep working until you save and confirm the new set.") },
            confirmButton = {
                Button(modifier = Modifier.heightIn(min = 48.dp), onClick = { showReplaceRecovery = false; beginRecoveryRotation() }) {
                    Text("Create new codes")
                }
            },
            dismissButton = { TextButton(modifier = Modifier.heightIn(min = 48.dp), onClick = { showReplaceRecovery = false }) { Text("Cancel") } },
        )
    }

    if (recoveryCodes.isNotEmpty()) {
        RecoveryCodesDialog(
            codes = recoveryCodes,
            confirming = confirmingRecovery,
            error = recoveryError,
            onDismiss = { if (!confirmingRecovery) recoveryCodes = emptyList() },
            onConfirm = {
                confirmingRecovery = true
                recoveryError = null
                recoveryNotice = null
                scope.launch {
                    runCatching { recoveryAuth.confirmRotation() }
                        .onSuccess {
                            recoveryStatus = it
                            recoveryCodes = emptyList()
                            recoveryNotice = "Recovery codes saved. Your previous set no longer works."
                        }
                        .onFailure { recoveryError = it.message ?: "Could not confirm recovery codes." }
                    confirmingRecovery = false
                }
            },
        )
    }
}

@Composable
private fun RecoveryCodesDialog(
    codes: List<String>,
    confirming: Boolean,
    error: String?,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    val context = LocalContext.current
    var saved by remember(codes) { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = { if (!confirming) onDismiss() },
        title = { Text("Save recovery codes") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Store these somewhere safe. They are shown only until you confirm that you saved them.")
                codes.forEach { code -> Text(code, style = MaterialTheme.typography.bodyMedium) }
                OutlinedButton(
                    onClick = {
                        val clip = ClipData.newPlainText("Media Tools recovery codes", codes.joinToString("\n"))
                        if (Build.VERSION.SDK_INT >= 33) {
                            clip.description.extras = PersistableBundle().apply {
                                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                            }
                        }
                        context.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
                    },
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                ) { Text("Copy all codes") }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = saved, onCheckedChange = { saved = it })
                    Text("I saved these recovery codes")
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            Button(modifier = Modifier.heightIn(min = 48.dp), enabled = saved && !confirming, onClick = onConfirm) {
                Text(if (confirming) "Confirming…" else "Confirm saved")
            }
        },
        dismissButton = { TextButton(modifier = Modifier.heightIn(min = 48.dp), enabled = !confirming, onClick = onDismiss) { Text("Not yet") } },
    )
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
    TextButton(onClick = action, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
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
                Text("With automatic transcription on, new recordings go to OpenAI when they are saved, and their transcripts go to OpenRouter. Everything else is sent only when you use an AI feature. Permission applies to this account on this Android device.")
                Text("OpenAI receives audio for transcription and may process text if the primary AI route is unavailable. API content is not used to train OpenAI models by default.")
                Text("OpenRouter and the selected model provider receive transcript or document text and chat prompts for formatting, summaries, citations, and answers. Media Tools requires zero-data-retention providers.")
                Text("You can revoke permission for future requests in Settings. Processing you already started may finish.")
                TextButton(modifier = Modifier.heightIn(min = 48.dp), onClick = onOpenDetails) { Text("Read AI and privacy details") }
            }
        },
        confirmButton = { Button(modifier = Modifier.heightIn(min = 48.dp), onClick = onAllow) { Text("Allow AI processing") } },
        dismissButton = { TextButton(modifier = Modifier.heightIn(min = 48.dp), onClick = onDecline) { Text("Not now") } },
    )
}

@Composable
private fun DeleteAccountDialog(
    api: MediaToolsApi,
    passwordConfigured: Boolean?,
    onDismiss: () -> Unit,
    onDeleted: () -> Unit,
    onError: (String) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var confirmation by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var submitting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // Accounts with a password must prove it. If status could not be loaded, still offer
    // the field so a password account can proceed; the server decides.
    val askPassword = passwordConfigured != false

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
                if (askPassword) {
                    OutlinedTextField(
                        value = password,
                        onValueChange = { password = it.take(1024); error = null },
                        label = { Text(if (passwordConfigured == true) "Your password" else "Your password (if you set one)") },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            Button(
                enabled = confirmation == "DELETE" && !submitting && (passwordConfigured != true || password.isNotEmpty()),
                modifier = Modifier.heightIn(min = 48.dp),
                onClick = {
                    submitting = true
                    error = null
                    scope.launch {
                        runCatching { api.deleteAccount(password) }
                            .onSuccess { onDeleted() }
                            .onFailure {
                                val message = it.authFailureMessage()
                                error = message
                                onError(message)
                            }
                        submitting = false
                    }
                },
            ) { Text(if (submitting) "Deleting…" else "Permanently delete") }
        },
        dismissButton = {
            TextButton(enabled = !submitting, modifier = Modifier.heightIn(min = 48.dp), onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun ChangePasswordDialog(
    passwordAuth: PasswordAuthController,
    hasPassword: Boolean,
    onDismiss: () -> Unit,
    onChanged: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var current by remember { mutableStateOf("") }
    var new by remember { mutableStateOf("") }
    var submitting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val ready = new.isNotEmpty() && (!hasPassword || current.isNotEmpty())

    AlertDialog(
        onDismissRequest = { if (!submitting) onDismiss() },
        title = { Text(if (hasPassword) "Change password" else "Set a password") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (hasPassword) {
                    OutlinedTextField(
                        value = current,
                        onValueChange = { current = it.take(1024); error = null },
                        label = { Text("Current password") },
                        singleLine = true,
                        enabled = !submitting,
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                OutlinedTextField(
                    value = new,
                    onValueChange = { new = it.take(1024); error = null },
                    label = { Text("New password") },
                    supportingText = { Text("12 to 128 characters") },
                    singleLine = true,
                    enabled = !submitting,
                    isError = new.isNotEmpty() && !isAcceptablePassword(new),
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    modifier = Modifier.fillMaxWidth(),
                )
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            Button(
                enabled = ready && !submitting,
                modifier = Modifier.heightIn(min = 48.dp),
                onClick = {
                    submitting = true
                    error = null
                    scope.launch {
                        runCatching { passwordAuth.changePassword(current.takeIf { hasPassword }, new) }
                            .onSuccess { onChanged() }
                            .onFailure { error = it.authFailureMessage() }
                        submitting = false
                    }
                },
            ) { Text(if (submitting) "Saving…" else "Save password") }
        },
        dismissButton = {
            TextButton(enabled = !submitting, modifier = Modifier.heightIn(min = 48.dp), onClick = onDismiss) { Text("Cancel") }
        },
    )
}

private fun openUrl(context: android.content.Context, url: String) {
    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
}
