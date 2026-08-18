import java.util.Properties
import java.io.FileInputStream
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Signing material lives outside the repository and is shared with the other
// Flutter projects on this machine.
val keystorePropertiesFile = file(System.getProperty("user.home") + "/.my-safe/key.properties")
val keystoreProperties = Properties()
keystoreProperties.load(FileInputStream(keystorePropertiesFile))

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "a.a.easysend"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications uses java.time, which needs desugaring
        // to run on the older Android versions we still support.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "a.a.easysend"
        // 23 is what permission_handler needs for runtime permissions.
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // FileProvider, used to hand a picked or received file to another app.
    implementation("androidx.core:core:1.13.1")
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

// With --split-per-abi the Flutter plugin rewrites each APK's version code as
// abi * 1000 + build, so one build reads as 2055 on arm64 and 4055 on x86_64.
// A store needs that ordering; these APKs are installed by hand, where it only
// hides which build is on the device.
//
// Registered here rather than in afterEvaluate, where the property is already
// closed for writing: the plugin hooks the variants from its own apply(), so an
// action added below it in this script still runs second and wins.
@Suppress("DEPRECATION")
(extensions.getByName("android") as com.android.build.gradle.AppExtension)
    .applicationVariants
    .all {
        outputs.all {
            (this as com.android.build.gradle.api.ApkVariantOutput).versionCodeOverride =
                flutter.versionCode
        }
    }
