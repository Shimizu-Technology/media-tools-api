package com.shimizutechnology.mediatools.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val Brand = Color(0xFF35B8A6)
val BrandStrong = Color(0xFF209A8C)
val Canvas = Color(0xFF090B0F)
val Surface = Color(0xFF12161C)
val SurfaceRaised = Color(0xFF1A2028)
val Border = Color(0xFF2A323D)
val TextPrimary = Color(0xFFF3F5F7)
val TextSecondary = Color(0xFFA8B0BC)
val Danger = Color(0xFFFF5E65)
val Warning = Color(0xFFFFB454)

private val colors = darkColorScheme(
    primary = Brand,
    onPrimary = Color(0xFF041411),
    primaryContainer = Color(0xFF163B36),
    onPrimaryContainer = TextPrimary,
    secondary = Color(0xFF91A4FF),
    background = Canvas,
    onBackground = TextPrimary,
    surface = Surface,
    onSurface = TextPrimary,
    surfaceVariant = SurfaceRaised,
    onSurfaceVariant = TextSecondary,
    outline = Border,
    error = Danger,
)

@Composable
fun MediaToolsTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = colors, content = content)
}
