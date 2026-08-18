pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// AGP stays on 8.x on purpose, and Flutter's "upgrade to 9" warning is left
// unanswered: package_info_plus and wakelock_plus stop applying the Kotlin
// plugin as soon as AGP reports a major of 9 and hand the job to AGP's built-in
// Kotlin, which this project has off (android.builtInKotlin=false, as in
// Flutter's own template). Their classes then never get compiled and the app
// fails to link them. Revisit when those plugins no longer need it.
plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
