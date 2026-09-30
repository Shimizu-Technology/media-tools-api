package com.shimizutechnology.mediatools.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Button
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.clerk.api.Clerk
import com.clerk.api.network.serialization.ClerkResult
import com.clerk.api.session.pendingTaskKey
import com.clerk.ui.auth.AuthView
import com.shimizutechnology.mediatools.AppLinks
import com.shimizutechnology.mediatools.BuildConfig
import com.shimizutechnology.mediatools.MediaToolsApplication
import com.shimizutechnology.mediatools.api.ClerkSessionTokenProvider
import com.shimizutechnology.mediatools.api.AndroidDeviceSessionStore
import com.shimizutechnology.mediatools.api.DeviceSessionController
import com.shimizutechnology.mediatools.api.MediaToolsApi
import com.shimizutechnology.mediatools.api.OkHttpDeviceSessionTransport
import com.shimizutechnology.mediatools.api.RecoveryAuthController
import com.shimizutechnology.mediatools.api.SessionTokenProvider
import com.shimizutechnology.mediatools.consent.AIProcessingConsentStore
import com.shimizutechnology.mediatools.consent.AndroidConsentPreferences
import com.shimizutechnology.mediatools.ui.library.LibraryDetailScreen
import com.shimizutechnology.mediatools.ui.library.LibraryScreen
import com.shimizutechnology.mediatools.ui.library.LibraryViewModel
import com.shimizutechnology.mediatools.ui.settings.SettingsScreen
import kotlinx.coroutines.launch

@Composable
fun MediaToolsApp() {
    val context = LocalContext.current
    val consentStore = remember { AIProcessingConsentStore(AndroidConsentPreferences(context.applicationContext)) }
    val sessionStore = remember { AndroidDeviceSessionStore(context.applicationContext) }
    val sessionTransport = remember { OkHttpDeviceSessionTransport(BuildConfig.API_BASE_URL) }
    val deviceSession = remember(sessionStore, sessionTransport) {
        DeviceSessionController(
            sessionStore,
            sessionTransport,
            currentExternalIdentity = { Clerk.user?.id },
        )
    }
    val recoveryAuth = remember(sessionStore, sessionTransport, deviceSession) {
        RecoveryAuthController(
            sessionStore,
            sessionTransport,
            deviceSession,
            deviceName = { android.os.Build.MODEL ?: "Android" },
        )
    }
    val clerkConfigured = MediaToolsApplication.isClerkConfigured(BuildConfig.CLERK_PUBLISHABLE_KEY)
    if (!clerkConfigured && !BuildConfig.FIRST_PARTY_ANDROID_AUTH_ENABLED) {
        SetupRequiredScreen()
        return
    }

    val initialized by Clerk.isInitialized.collectAsState(initial = false)
    val initializationError by Clerk.initializationError.collectAsState(initial = null)
    val session by Clerk.sessionFlow.collectAsState(initial = Clerk.session)
    val user by Clerk.userFlow.collectAsState(initial = Clerk.user)
    // Collecting the revision makes bootstrap, revocation, and invalidation
    // immediately update the visible account workspace.
    val sessionRevision by deviceSession.revision.collectAsState()
    val clerkId = user?.id
    val accountConflict = BuildConfig.FIRST_PARTY_ANDROID_AUTH_ENABLED &&
        deviceSession.hasConflictingExternalIdentity(clerkId)
    val durableOwnerId = remember(sessionRevision, clerkId) {
        if (BuildConfig.FIRST_PARTY_ANDROID_AUTH_ENABLED) deviceSession.availableOwnerId(clerkId) else null
    }
    LaunchedEffect(clerkId, session?.id, durableOwnerId, accountConflict) {
        if (BuildConfig.FIRST_PARTY_ANDROID_AUTH_ENABLED && !accountConflict && clerkId != null && session != null &&
            session?.pendingTaskKey == null && durableOwnerId == null
        ) {
            runCatching {
                val clerkToken = ClerkSessionTokenProvider().token(clerkId)
                deviceSession.bootstrap(clerkId, clerkToken, android.os.Build.MODEL ?: "Android")
            }.onSuccess {
                consentStore.migrateVerifiedOwner(clerkId, it.userId)
            }
        }
    }
    val migration = if (BuildConfig.FIRST_PARTY_ANDROID_AUTH_ENABLED) deviceSession.verifiedMigration else null
    LaunchedEffect(migration) {
        migration?.let { (verifiedClerkId, userId) ->
            // The stored mapping was originally returned by the verified server bootstrap.
            consentStore.migrateVerifiedOwner(verifiedClerkId, userId)
        }
    }
    when {
        accountConflict -> AccountSwitchScreen(onSwitch = { deviceSession.revokeAndClear() })
        durableOwnerId != null -> key("device:$durableOwnerId") {
            SignedInApp(
                ownerId = durableOwnerId,
                tokenProvider = deviceSession,
                consentStore = consentStore,
                recoveryAuth = recoveryAuth,
                onSignOut = {
                    if (Clerk.session != null && Clerk.auth.signOut() is ClerkResult.Failure) {
                        throw IllegalStateException("Could not finish signing out of the previous sign-in service.")
                    }
                    deviceSession.revokeAndClear()
                },
                onDeleted = {
                    deviceSession.clearAfterDeletion()
                    if (Clerk.session != null && Clerk.auth.signOut() is ClerkResult.Failure) {
                        throw IllegalStateException("Account deletion is underway, but sign-out could not finish.")
                    }
                },
            )
        }
        initializationError != null && !BuildConfig.FIRST_PARTY_ANDROID_AUTH_ENABLED -> AuthUnavailableScreen()
        clerkConfigured && !initialized && !BuildConfig.FIRST_PARTY_ANDROID_AUTH_ENABLED -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator()
        }
        !clerkConfigured || !initialized || user == null || session == null || session?.pendingTaskKey != null -> {
            if (BuildConfig.FIRST_PARTY_ANDROID_AUTH_ENABLED) {
                SignInScreen(
                    recoveryAuth = recoveryAuth,
                    showClerk = clerkConfigured && initialized && initializationError == null,
                )
            } else {
                AuthView(modifier = Modifier.fillMaxSize())
            }
        }
        else -> key("clerk:${user!!.id}") {
            SignedInApp(
                ownerId = user!!.id,
                tokenProvider = ClerkSessionTokenProvider(),
                consentStore = consentStore,
                recoveryAuth = null,
                onSignOut = {
                    if (Clerk.auth.signOut() is ClerkResult.Failure) {
                        throw IllegalStateException("Could not sign out.")
                    }
                },
                onDeleted = {
                    if (Clerk.auth.signOut() is ClerkResult.Failure) {
                        throw IllegalStateException("Could not finish signing out.")
                    }
                },
            )
        }
    }
}

@Composable
private fun SignInScreen(recoveryAuth: RecoveryAuthController, showClerk: Boolean) {
    val scope = rememberCoroutineScope()
    var showRecovery by remember { mutableStateOf(false) }
    var recoveryCode by remember { mutableStateOf("") }
    var submitting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    Column(Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("Sign in to Media Tools", style = androidx.compose.material3.MaterialTheme.typography.headlineSmall)
            Text(
                "Use a recovery code if your usual sign-in is unavailable.",
                color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            Button(onClick = { error = null; showRecovery = true }, modifier = Modifier.fillMaxWidth()) {
                Text("Use a recovery code")
            }
        }
        if (showClerk) {
            AuthView(modifier = Modifier.fillMaxWidth().weight(1f).heightIn(min = 320.dp))
        } else {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    "Sign in securely with a recovery code you saved earlier.",
                    color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }

    if (showRecovery) {
        AlertDialog(
            onDismissRequest = { if (!submitting) showRecovery = false },
            title = { Text("Use a recovery code") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Enter one of the one-time codes you saved for this account.")
                    OutlinedTextField(
                        value = recoveryCode,
                        onValueChange = { recoveryCode = it.uppercase().take(44); error = null },
                        label = { Text("Recovery code") },
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    error?.let { Text(it, color = androidx.compose.material3.MaterialTheme.colorScheme.error) }
                }
            },
            confirmButton = {
                Button(
                    enabled = recoveryCode.isNotBlank() && !submitting,
                    onClick = {
                        submitting = true
                        error = null
                        scope.launch {
                            runCatching { recoveryAuth.redeem(recoveryCode) }
                                .onSuccess {
                                    recoveryCode = ""
                                    showRecovery = false
                                }
                                .onFailure { error = it.message ?: "Recovery sign-in could not be completed." }
                            submitting = false
                        }
                    },
                ) { Text(if (submitting) "Signing in…" else "Sign in") }
            },
            dismissButton = {
                TextButton(enabled = !submitting, onClick = { showRecovery = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun AccountSwitchScreen(onSwitch: suspend () -> Unit) {
    val scope = rememberCoroutineScope()
    var message by remember { mutableStateOf<String?>(null) }
    var switching by remember { mutableStateOf(false) }
    Column(
        modifier = Modifier.fillMaxSize().padding(28.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Switch accounts", style = androidx.compose.material3.MaterialTheme.typography.headlineSmall)
        Text(
            "This device still has a session for your previous account. Sign out of it before opening the new account.",
            modifier = Modifier.padding(top = 12.dp),
            textAlign = TextAlign.Center,
        )
        Button(
            enabled = !switching,
            onClick = {
                switching = true
                message = null
                scope.launch {
                    try {
                        onSwitch()
                    } catch (_: Exception) {
                        message = "Could not close the previous session. Check your connection and try again."
                    } finally {
                        switching = false
                    }
                }
            },
            modifier = Modifier.padding(top = 20.dp),
        ) { Text(if (switching) "Switching…" else "Sign out previous account") }
        message?.let { Text(it, modifier = Modifier.padding(top = 12.dp)) }
    }
}

@Composable
private fun AuthUnavailableScreen() {
    val context = LocalContext.current
    Column(
        modifier = Modifier.fillMaxSize().padding(28.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Sign-in service unavailable", style = androidx.compose.material3.MaterialTheme.typography.headlineSmall)
        Text(
            "Media Tools could not finish secure sign-in setup. Check your connection and reopen the app. If it continues, contact support.",
            modifier = Modifier.padding(top = 12.dp),
            textAlign = TextAlign.Center,
            color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
        )
        androidx.compose.material3.TextButton(
            modifier = Modifier.padding(top = 12.dp),
            onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(AppLinks.SUPPORT))) },
        ) { Text("Open support") }
    }
}

@Composable
private fun SignedInApp(
    ownerId: String,
    tokenProvider: SessionTokenProvider,
    consentStore: AIProcessingConsentStore,
    recoveryAuth: RecoveryAuthController?,
    onSignOut: suspend () -> Unit,
    onDeleted: suspend () -> Unit,
) {
    val api = remember(tokenProvider) { MediaToolsApi(BuildConfig.API_BASE_URL, tokenProvider) }
    val libraryViewModel: LibraryViewModel = viewModel(
        key = "library:$ownerId",
        factory = LibraryViewModel.factory(api),
    )
    val navController = rememberNavController()
    val currentRoute = navController.currentBackStackEntryAsState().value?.destination?.route
    val topLevelRoutes = setOf("library", "settings")

    Scaffold(
        bottomBar = {
            if (currentRoute in topLevelRoutes) {
                NavigationBar {
                    listOf(
                        Triple("library", "Library", Icons.Outlined.Folder),
                        Triple("settings", "Settings", Icons.Outlined.Settings),
                    ).forEach { (route, label, icon) ->
                        NavigationBarItem(
                            selected = currentRoute == route,
                            onClick = {
                                navController.navigate(route) {
                                    popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            },
                            icon = { Icon(icon, contentDescription = null) },
                            label = { Text(label) },
                        )
                    }
                }
            }
        },
    ) { padding ->
        NavHost(
            navController = navController,
            startDestination = "library",
            modifier = Modifier.padding(padding),
        ) {
            composable("library") {
                LibraryScreen(
                    viewModel = libraryViewModel,
                    onOpenItem = { type, id -> navController.navigate("detail/$type/$id") },
                )
            }
            composable(
                route = "detail/{type}/{id}",
                arguments = listOf(
                    navArgument("type") { type = NavType.StringType },
                    navArgument("id") { type = NavType.StringType },
                ),
            ) { entry ->
                LibraryDetailScreen(
                    api = api,
                    itemType = entry.arguments?.getString("type").orEmpty(),
                    itemId = entry.arguments?.getString("id").orEmpty(),
                    onBack = navController::popBackStack,
                )
            }
            composable("settings") {
                SettingsScreen(
                    api = api,
                    consentStore = consentStore,
                    ownerId = ownerId,
                    recoveryAuth = recoveryAuth,
                    onSignOut = onSignOut,
                    onDeleted = onDeleted,
                )
            }
        }
    }
}

@Composable
private fun SetupRequiredScreen() {
    val context = LocalContext.current
    LaunchedEffect(Unit) {
        // Intentionally do not initialize Clerk with a placeholder. This state is visible in
        // developer builds until the publishable key is supplied outside source control.
    }
    Column(
        modifier = Modifier.fillMaxSize().padding(28.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Android sign-in setup required", style = androidx.compose.material3.MaterialTheme.typography.headlineSmall)
        Text(
            "This build is missing its Clerk development publishable key. Add it to your local Gradle properties, then configure the Android package in Clerk before testing sign-in.",
            modifier = Modifier.padding(top = 12.dp),
            textAlign = TextAlign.Center,
            color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
        )
        androidx.compose.material3.TextButton(
            modifier = Modifier.padding(top = 12.dp),
            onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(AppLinks.SUPPORT))) },
        ) { Text("Open support") }
    }
}
