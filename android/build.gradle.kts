allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Plugins that declare no compileOptions leave their Java tasks on AGP's old
// default (1.8) while Kotlin follows the running JDK, and the build stops with
// "Inconsistent JVM-target compatibility". Pin every subproject to 17, the
// version the app itself uses.
fun Project.alignJvmTarget17() {
    val android = extensions.findByName("android")
    if (android is com.android.build.gradle.BaseExtension) {
        android.compileOptions {
            sourceCompatibility = JavaVersion.VERSION_17
            targetCompatibility = JavaVersion.VERSION_17
        }
    }
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile>().configureEach {
        compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

// ':app' is evaluated before any plugin (see evaluationDependsOn above), so by
// the time a plugin is configured its compileSdk is already readable.
val appCompileSdk: Int? by lazy {
    val android = project(":app").extensions.findByName("android")
    (android as? com.android.build.gradle.BaseExtension)
        ?.compileSdkVersion
        ?.substringAfter("android-")
        ?.toIntOrNull()
}

// A plugin can pin a compileSdk below what its own dependencies demand, and
// the AAR metadata check then stops the build. android_id and
// receive_sharing_intent still ask for 34, permission_handler and
// flutter_local_notifications for 35. Raise anything that sits below the app's
// own compileSdk.
fun Project.raiseCompileSdkToApp() {
    val android = extensions.findByName("android")
    if (android !is com.android.build.gradle.BaseExtension) return
    val appSdk = appCompileSdk ?: return
    val pluginSdk = android.compileSdkVersion?.substringAfter("android-")?.toIntOrNull() ?: return
    if (pluginSdk < appSdk) {
        android.compileSdkVersion(appSdk)
    }
}

subprojects {
    // ':app' is already evaluated here, forced by evaluationDependsOn above,
    // so its compileOptions are finalized and cannot be changed any more. It
    // needs no help anyway: it sets 17 itself. Only the plugins do.
    if (state.executed) return@subprojects
    afterEvaluate {
        alignJvmTarget17()
        raiseCompileSdkToApp()
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
