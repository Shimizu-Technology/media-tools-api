package com.shimizutechnology.mediatools.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
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
import com.clerk.api.session.pendingTaskKey
import com.clerk.ui.auth.AuthView
import com.shimizutechnology.mediatools.AppLinks
import com.shimizutechnology.mediatools.BuildConfig
import com.shimizutechnology.mediatools.MediaToolsApplication
import com.shimizutechnology.mediatools.api.ClerkSessionTokenProvider
import com.shimizutechnology.mediatools.api.MediaToolsApi
import com.shimizutechnology.mediatools.consent.AIProcessingConsentStore
import com.shimizutechnology.mediatools.consent.AndroidConsentPreferences
import com.shimizutechnology.mediatools.ui.library.LibraryDetailScreen
import com.shimizutechnology.mediatools.ui.library.LibraryScreen
import com.shimizutechnology.mediatools.ui.library.LibraryViewModel
import com.shimizutechnology.mediatools.ui.settings.SettingsScreen

@Composable
fun MediaToolsApp() {
    if (!MediaToolsApplication.isClerkConfigured(BuildConfig.CLERK_PUBLISHABLE_KEY)) {
        SetupRequiredScreen()
        return
    }

    val initialized by Clerk.isInitialized.collectAsState(initial = false)
    val initializationError by Clerk.initializationError.collectAsState(initial = null)
    val session by Clerk.sessionFlow.collectAsState(initial = Clerk.session)
    val user by Clerk.userFlow.collectAsState(initial = Clerk.user)
    when {
        initializationError != null -> AuthUnavailableScreen()
        !initialized -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator()
        }
        user == null || session == null || session?.pendingTaskKey != null -> AuthView(modifier = Modifier.fillMaxSize())
        else -> key(user!!.id) { SignedInApp(ownerId = user!!.id) }
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
private fun SignedInApp(ownerId: String) {
    val context = LocalContext.current
    val api = remember { MediaToolsApi(BuildConfig.API_BASE_URL, ClerkSessionTokenProvider()) }
    val consentStore = remember { AIProcessingConsentStore(AndroidConsentPreferences(context)) }
    val libraryViewModel: LibraryViewModel = viewModel(factory = LibraryViewModel.factory(api))
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
                SettingsScreen(api = api, consentStore = consentStore, ownerId = ownerId)
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
