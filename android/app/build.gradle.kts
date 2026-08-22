import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.shimizutechnology.mediatools"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.shimizutechnology.mediatools"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        val isCI = System.getenv("CI")?.toBoolean() == true
        val clerkKey = providers.gradleProperty("MEDIA_TOOLS_CLERK_PUBLISHABLE_KEY")
            .orElse(providers.environmentVariable("MEDIA_TOOLS_CLERK_PUBLISHABLE_KEY"))
            .orNull
        if (clerkKey.isNullOrBlank() && !isCI) {
            logger.warn(
                "MEDIA_TOOLS_CLERK_PUBLISHABLE_KEY is unset. The app will build, but sign-in will show setup guidance."
            )
        }
        val configuredKey = clerkKey ?: "pk_test_placeholder_for_ci"
        buildConfigField("String", "CLERK_PUBLISHABLE_KEY", "\"$configuredKey\"")
        buildConfigField("String", "API_BASE_URL", "\"https://media-tools-api-x9r7.onrender.com/api/v1\"")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin { compilerOptions { jvmTarget = JvmTarget.JVM_17 } }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    val releaseKeystorePath = providers.environmentVariable("MEDIA_TOOLS_ANDROID_KEYSTORE_PATH").orNull
    val releaseKeystorePassword = providers.environmentVariable("MEDIA_TOOLS_ANDROID_KEYSTORE_PASSWORD").orNull
    val releaseKeyAlias = providers.environmentVariable("MEDIA_TOOLS_ANDROID_KEY_ALIAS").orNull
    val releaseKeyPassword = providers.environmentVariable("MEDIA_TOOLS_ANDROID_KEY_PASSWORD").orNull
    if (listOf(releaseKeystorePath, releaseKeystorePassword, releaseKeyAlias, releaseKeyPassword).all { !it.isNullOrBlank() }) {
        signingConfigs.create("release") {
            storeFile = file(requireNotNull(releaseKeystorePath))
            storePassword = releaseKeystorePassword
            keyAlias = releaseKeyAlias
            keyPassword = releaseKeyPassword
        }
        buildTypes.getByName("release").signingConfig = signingConfigs.getByName("release")
    }

    packaging.resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}")
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.navigation.compose)
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.icons)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.clerk.ui)
    implementation(libs.kotlinx.serialization)
    implementation(libs.kotlinx.coroutines)
    implementation(libs.okhttp)

    debugImplementation(libs.compose.ui.tooling)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.mockwebserver)
}
