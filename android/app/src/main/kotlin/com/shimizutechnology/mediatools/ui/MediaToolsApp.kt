package com.shimizutechnology.mediatools.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.shimizutechnology.mediatools.BuildConfig
import com.shimizutechnology.mediatools.api.AndroidDeviceSessionStore
import com.shimizutechnology.mediatools.api.DeviceSessionController
import com.shimizutechnology.mediatools.api.MediaToolsApi
import com.shimizutechnology.mediatools.api.OkHttpDeviceSessionTransport
import com.shimizutechnology.mediatools.api.PasswordAuthController
import com.shimizutechnology.mediatools.api.RecoveryAuthController
import com.shimizutechnology.mediatools.api.SessionTokenProvider
import com.shimizutechnology.mediatools.consent.AIProcessingConsentStore
import com.shimizutechnology.mediatools.consent.AndroidConsentPreferences
import com.shimizutechnology.mediatools.ui.library.LibraryDetailScreen
import com.shimizutechnology.mediatools.ui.library.LibraryScreen
import com.shimizutechnology.mediatools.ui.library.LibraryViewModel
import com.shimizutechnology.mediatools.ui.auth.AuthScreen
import com.shimizutechnology.mediatools.ui.auth.AuthViewModel
import com.shimizutechnology.mediatools.ui.settings.SettingsScreen

@Composable
fun MediaToolsApp() {
    val context = LocalContext.current
    val consentStore = remember { AIProcessingConsentStore(AndroidConsentPreferences(context.applicationContext)) }
    val sessionStore = remember { AndroidDeviceSessionStore(context.applicationContext) }
    val sessionTransport = remember { OkHttpDeviceSessionTransport(BuildConfig.API_BASE_URL) }
    val deviceSession = remember(sessionStore, sessionTransport) {
        DeviceSessionController(sessionStore, sessionTransport)
    }
    val deviceName = { android.os.Build.MODEL ?: "Android" }
    val recoveryAuth = remember(sessionStore, sessionTransport, deviceSession) {
        RecoveryAuthController(sessionStore, sessionTransport, deviceSession, deviceName)
    }
    val passwordAuth = remember(sessionStore, sessionTransport, deviceSession) {
        PasswordAuthController(sessionStore, sessionTransport, deviceSession, deviceName)
    }

    // Collecting the revision makes sign-in, revocation, and a rejected refresh
    // immediately update the visible account workspace.
    val sessionRevision by deviceSession.revision.collectAsState()
    val ownerId = remember(sessionRevision) { deviceSession.currentOwnerId() }
    val migration = remember(sessionRevision) { deviceSession.verifiedMigration }
    LaunchedEffect(migration) {
        migration?.let { (legacyId, userId) ->
            // Sessions saved by earlier builds recorded the old sign-in id. Move this
            // device's AI consent to the stable account id once.
            consentStore.migrateVerifiedOwner(legacyId, userId)
        }
    }

    if (ownerId != null) {
        key("device:$ownerId") {
            SignedInApp(
                ownerId = ownerId,
                tokenProvider = deviceSession,
                consentStore = consentStore,
                recoveryAuth = recoveryAuth,
                passwordAuth = passwordAuth,
                onSignOut = { deviceSession.revokeAndClear() },
                onDeleted = { deviceSession.clearAfterDeletion() },
            )
        }
    } else {
        val authViewModel: AuthViewModel = viewModel(factory = AuthViewModel.factory(passwordAuth))
        AuthScreen(authViewModel, recoveryAuth)
    }
}

@Composable
private fun SignedInApp(
    ownerId: String,
    tokenProvider: SessionTokenProvider,
    consentStore: AIProcessingConsentStore,
    recoveryAuth: RecoveryAuthController,
    passwordAuth: PasswordAuthController,
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
                    passwordAuth = passwordAuth,
                    onSignOut = onSignOut,
                    onDeleted = onDeleted,
                )
            }
        }
    }
}
