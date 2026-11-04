package com.shimizutechnology.mediatools.ui.auth

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.shimizutechnology.mediatools.api.RecoveryAuthController
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Every tappable control is at least this tall. */
private val MinTouch = 48.dp

@Composable
fun AuthScreen(viewModel: AuthViewModel, recoveryAuth: RecoveryAuthController) {
    val state by viewModel.state.collectAsState()
    var showRecovery by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .imePadding()
            .padding(horizontal = 24.dp, vertical = 32.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        when (state.step) {
            AuthStep.SignIn -> SignInStep(viewModel, state, onRecovery = { showRecovery = true })
            AuthStep.SignUp -> SignUpStep(viewModel, state)
            AuthStep.SignUpCode -> CodeStep(
                viewModel = viewModel,
                state = state,
                title = "Check your email",
                action = "Create account",
                newPasswordLabel = "Choose a password",
                onSubmit = viewModel::completeSignup,
                backLabel = "Use a different email",
                backTo = AuthStep.SignUp,
            )
            AuthStep.ForgotPassword -> ForgotStep(viewModel, state)
            AuthStep.ResetCode -> CodeStep(
                viewModel = viewModel,
                state = state,
                title = "Reset your password",
                action = "Reset password",
                newPasswordLabel = "New password",
                onSubmit = viewModel::completeReset,
                backLabel = "Use a different email",
                backTo = AuthStep.ForgotPassword,
            )
        }
    }

    if (showRecovery) RecoveryCodeDialog(recoveryAuth) { showRecovery = false }
}

@Composable
private fun SignInStep(viewModel: AuthViewModel, state: AuthUiState, onRecovery: () -> Unit) {
    var password by remember { mutableStateOf("") }
    val submit = { viewModel.signIn(password) }

    Heading("Sign in to Media Tools")
    state.notice?.let { Notice(it) }
    EmailField(state.email, viewModel::setEmail, ImeAction.Next, enabled = !state.busy)
    PasswordField(
        value = password,
        onChange = { password = it },
        label = "Password",
        new = false,
        imeAction = ImeAction.Done,
        enabled = !state.busy,
        onDone = submit,
    )
    ErrorText(state.error)
    PrimaryButton("Sign in", busy = state.busy, enabled = password.isNotEmpty() && state.email.isNotBlank(), onClick = submit)
    LinkButton("Forgot password?", enabled = !state.busy) { viewModel.go(AuthStep.ForgotPassword) }
    if (state.signupEnabled) {
        LinkButton("Create an account", enabled = !state.busy) { viewModel.go(AuthStep.SignUp) }
    }
    LinkButton("Use a recovery code", enabled = !state.busy, onClick = onRecovery)
}

@Composable
private fun SignUpStep(viewModel: AuthViewModel, state: AuthUiState) {
    var name by remember { mutableStateOf("") }
    val submit = { viewModel.startSignup(name) }

    Heading("Create your account")
    Body("We will email a 6-digit code to confirm your address.")
    EmailField(state.email, viewModel::setEmail, ImeAction.Next, enabled = !state.busy)
    OutlinedTextField(
        value = name,
        onValueChange = { name = it.take(200) },
        label = { Text("Name (optional)") },
        singleLine = true,
        enabled = !state.busy,
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { submit() }),
        modifier = Modifier.fillMaxWidth().semantics { contentType = ContentType.PersonFullName },
    )
    ErrorText(state.error)
    PrimaryButton("Send code", busy = state.busy, enabled = state.email.isNotBlank(), onClick = submit)
    LinkButton("Already have an account? Sign in", enabled = !state.busy) { viewModel.go(AuthStep.SignIn) }
}

@Composable
private fun ForgotStep(viewModel: AuthViewModel, state: AuthUiState) {
    Heading("Forgot your password?")
    Body("Enter your account email and we will send a 6-digit code to set a new password.")
    EmailField(state.email, viewModel::setEmail, ImeAction.Done, enabled = !state.busy, onDone = viewModel::startReset)
    ErrorText(state.error)
    PrimaryButton("Send code", busy = state.busy, enabled = state.email.isNotBlank(), onClick = viewModel::startReset)
    LinkButton("Back to sign in", enabled = !state.busy) { viewModel.go(AuthStep.SignIn) }
}

@Composable
private fun CodeStep(
    viewModel: AuthViewModel,
    state: AuthUiState,
    title: String,
    action: String,
    newPasswordLabel: String,
    onSubmit: (code: String, password: String) -> Unit,
    backLabel: String,
    backTo: AuthStep,
) {
    var code by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    val submit = { onSubmit(code, password) }
    val remainingSeconds = rememberSecondsUntil(state.resendAvailableAtMillis)

    Heading(title)
    // The same receipt for every address, so this screen never reveals whether one is registered.
    state.notice?.let { Notice(it) }
    Body("Enter the 6-digit code when it arrives. It expires in 10 minutes.")
    OutlinedTextField(
        value = code,
        onValueChange = { code = it.filter(Char::isDigit).take(6) },
        label = { Text("6-digit code") },
        singleLine = true,
        enabled = !state.busy,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Next),
        modifier = Modifier.fillMaxWidth().semantics { contentType = ContentType.SmsOtpCode },
    )
    PasswordField(
        value = password,
        onChange = { password = it },
        label = newPasswordLabel,
        new = true,
        imeAction = ImeAction.Done,
        enabled = !state.busy,
        onDone = submit,
    )
    Body("Use 12 to 128 characters.")
    ErrorText(state.error)
    PrimaryButton(action, busy = state.busy, enabled = code.length == 6 && password.isNotEmpty(), onClick = submit)
    LinkButton(
        if (remainingSeconds > 0) "Resend code in ${remainingSeconds}s" else "Resend code",
        enabled = !state.busy && remainingSeconds == 0L,
        onClick = viewModel::resendCode,
    )
    LinkButton(backLabel, enabled = !state.busy) { viewModel.go(backTo) }
}

/** Counts down to a wall-clock deadline once a second; 0 when there is nothing to wait for. */
@Composable
private fun rememberSecondsUntil(deadlineMillis: Long): Long {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(deadlineMillis) {
        now = System.currentTimeMillis()
        while (now < deadlineMillis) {
            delay(1000)
            now = System.currentTimeMillis()
        }
    }
    return ((deadlineMillis - now + 999) / 1000).coerceAtLeast(0)
}

@Composable
private fun Heading(text: String) {
    Text(text, style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
}

@Composable
private fun Body(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.Center,
    )
}

@Composable
private fun Notice(text: String) {
    Text(text, color = MaterialTheme.colorScheme.primary, textAlign = TextAlign.Center)
}

@Composable
private fun ErrorText(message: String?) {
    message?.let {
        Text(
            it,
            color = MaterialTheme.colorScheme.error,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun PrimaryButton(label: String, busy: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Button(
        enabled = enabled && !busy,
        onClick = onClick,
        modifier = Modifier.fillMaxWidth().heightIn(min = MinTouch),
    ) {
        if (busy) CircularProgressIndicator(Modifier.size(18.dp).padding(end = 0.dp), strokeWidth = 2.dp)
        else Text(label)
    }
}

@Composable
private fun LinkButton(label: String, enabled: Boolean, onClick: () -> Unit) {
    TextButton(enabled = enabled, onClick = onClick, modifier = Modifier.heightIn(min = MinTouch)) { Text(label) }
}

@Composable
private fun EmailField(
    value: String,
    onChange: (String) -> Unit,
    imeAction: ImeAction,
    enabled: Boolean,
    onDone: () -> Unit = {},
) {
    OutlinedTextField(
        value = value,
        onValueChange = { onChange(it.take(255)) },
        label = { Text("Email") },
        singleLine = true,
        enabled = enabled,
        keyboardOptions = KeyboardOptions(
            keyboardType = KeyboardType.Email,
            imeAction = imeAction,
            autoCorrectEnabled = false,
        ),
        keyboardActions = KeyboardActions(onDone = { onDone() }),
        modifier = Modifier.fillMaxWidth().semantics { contentType = ContentType.EmailAddress },
    )
}

@Composable
private fun PasswordField(
    value: String,
    onChange: (String) -> Unit,
    label: String,
    new: Boolean,
    imeAction: ImeAction,
    enabled: Boolean,
    onDone: () -> Unit,
) {
    var visible by remember { mutableStateOf(false) }
    OutlinedTextField(
        value = value,
        onValueChange = { onChange(it.take(1024)) },
        label = { Text(label) },
        singleLine = true,
        enabled = enabled,
        visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(
            keyboardType = KeyboardType.Password,
            imeAction = imeAction,
            autoCorrectEnabled = false,
        ),
        keyboardActions = KeyboardActions(onDone = { onDone() }),
        trailingIcon = {
            IconButton(onClick = { visible = !visible }, modifier = Modifier.size(MinTouch)) {
                Icon(
                    if (visible) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility,
                    contentDescription = if (visible) "Hide password" else "Show password",
                )
            }
        },
        modifier = Modifier.fillMaxWidth().semantics {
            contentType = if (new) ContentType.NewPassword else ContentType.Password
        },
    )
}

@Composable
private fun RecoveryCodeDialog(recoveryAuth: RecoveryAuthController, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf("") }
    var submitting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = { if (!submitting) onDismiss() },
        title = { Text("Use a recovery code") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Enter one of the one-time codes you saved for this account.")
                OutlinedTextField(
                    value = code,
                    onValueChange = { code = it.uppercase().take(44); error = null },
                    label = { Text("Recovery code") },
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            Button(
                enabled = code.isNotBlank() && !submitting,
                modifier = Modifier.heightIn(min = MinTouch),
                onClick = {
                    submitting = true
                    error = null
                    scope.launch {
                        runCatching { recoveryAuth.redeem(code) }
                            .onSuccess { code = ""; onDismiss() }
                            .onFailure { error = it.message ?: "Recovery sign-in could not be completed." }
                        submitting = false
                    }
                },
            ) { Text(if (submitting) "Signing in…" else "Sign in") }
        },
        dismissButton = {
            TextButton(enabled = !submitting, modifier = Modifier.heightIn(min = MinTouch), onClick = onDismiss) {
                Text("Cancel")
            }
        },
    )
}
