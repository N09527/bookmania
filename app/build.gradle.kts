import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    id("yokai.android.application")
    id("yokai.android.application.compose")
    alias(kotlinx.plugins.serialization)
    alias(kotlinx.plugins.parcelize)
    alias(libs.plugins.aboutlibraries)
    alias(libs.plugins.aboutlibraries.android)
}

fun runCommand(command: String): String {
    val result = providers.exec { commandLine(command.split(" ")) }
    return result.standardOutput.asText.get().trim()
}

// Bookmania's own version line (it started at 1.0.0 when it left Yōkai's 1.10.3; versionCode went on from 162 to 200,
// so installed copies update in place).
@Suppress("PropertyName")
val _versionName = "1.2.0"
val betaCount by lazy {
    val betaTags = runCommand("git tag -l --sort=refname v${_versionName}-b*")

    if (betaTags.isNotEmpty()) {
        val betaTag = betaTags.split("\n").last().substringAfter("-b").toIntOrNull()
        ((betaTag ?: 0) + 1)
    } else {
        1
    }.toString()
}
val commitCount by lazy { runCommand("git rev-list --count HEAD") }
val commitHash by lazy { runCommand("git rev-parse --short HEAD") }
val buildTime: String by lazy {
    val df = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'")
    LocalDateTime.now(ZoneOffset.UTC).format(df)
}

val supportedAbis = setOf("armeabi-v7a", "arm64-v8a", "x86", "x86_64")

android {
    defaultConfig {
        applicationId = "io.github.n09527.bookmania"
        versionCode = 202
        versionName = _versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        multiDexEnabled = true

        buildConfigField("String", "COMMIT_COUNT", "\"${commitCount}\"")
        buildConfigField("String", "BETA_COUNT", "\"${betaCount}\"")
        buildConfigField("String", "COMMIT_SHA", "\"${commitHash}\"")
        buildConfigField("String", "BUILD_TIME", "\"${buildTime}\"")
        // No self-updater: the in-app update check stays off (Bookmania is distributed as APKs on GitHub Releases).
        buildConfigField("Boolean", "INCLUDE_UPDATER", "false")
        buildConfigField("Boolean", "BETA", "false")
        buildConfigField("Boolean", "NIGHTLY", "false")
        // Whether the "Updated to vX / What's new" sheet is shown after an update.
        buildConfigField("Boolean", "SHOW_UPDATE_NOTES", "false")
        // Whether onboarding requires the "install apps" permission (used by a self-updater and extensions).
        buildConfigField("Boolean", "ONBOARDING_REQUIRES_INSTALL_PERMISSION", "false")

        ndk {
            // False positive, we have x86 abi support
            //noinspection ChromeOsAbiSupport
            abiFilters += supportedAbis
        }
    }

    splits {
        abi {
            isEnable = true
            reset()
            // False positive, we have x86 abi support
            //noinspection ChromeOsAbiSupport
            include(*supportedAbis.toTypedArray())
            isUniversalApk = true
        }
    }

    buildTypes {
        getByName("debug") {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-d${commitCount}"
        }
        getByName("release") {
            isShrinkResources = true
            isMinifyEnabled = true
            proguardFiles("proguard-android-optimize.txt", "proguard-rules.pro")
        }
    }

    buildFeatures {
        viewBinding = true
        // If you're here because there's not BuildConfig, build the app first, it'll generate it for you
        buildConfig = true

        // Disable some unused things
        aidl = false
        renderScript = false
        shaders = false
    }

    // Debug signing with a key of Bookmania's own, kept in the repository (app/debug.keystore): every debug build,
    // here, on GitHub Actions or on another computer, is signed alike, so the published debug APKs update each other
    // in place. It is public, as debug keys are; the release key below is not.
    signingConfigs.getByName("debug") {
        storeFile = file("debug.keystore")
        storePassword = "android"
        keyAlias = "androiddebugkey"
        keyPassword = "android"
    }

    // Release signing. The keystore and its passwords never go into the repository: set
    // bookmaniaStoreFile, bookmaniaStorePassword, bookmaniaKeyAlias and bookmaniaKeyPassword in
    // ~/.gradle/gradle.properties (or as ORG_GRADLE_PROJECT_* environment variables, as the release workflow does).
    // Without them the release APK is built unsigned.
    providers.gradleProperty("bookmaniaStoreFile").orNull?.let { path ->
        signingConfigs.create("bookmania") {
            storeFile = file(path)
            storePassword = providers.gradleProperty("bookmaniaStorePassword").get()
            keyAlias = providers.gradleProperty("bookmaniaKeyAlias").get()
            keyPassword = providers.gradleProperty("bookmaniaKeyPassword").get()
        }
    }

    flavorDimensions.add("default")

    // A single flavor: it keeps the task and APK names (assembleBookmaniaRelease, app-bookmania-*.apk).
    productFlavors {
        create("bookmania") {
            dimension = "default"
            // Debug builds keep the debug key (the build type's signing config wins).
            signingConfigs.findByName("bookmania")?.let { signingConfig = it }
        }
    }

    lint {
        disable.addAll(listOf("MissingTranslation", "ExtraTranslation"))
        abortOnError = false
        checkReleaseBuilds = false
    }

    namespace = "eu.kanade.tachiyomi"
}

dependencies {
    implementation(projects.core.archive)
    implementation(projects.core.ebook)
    implementation(projects.core.main)
    implementation(projects.data)
    implementation(projects.domain)
    implementation(projects.i18n)
    implementation(projects.presentation.core)
    implementation(projects.source.api)

    // Compose
    implementation(platform(compose.bom))
    implementation(compose.bundles.compose)
    debugImplementation(compose.ui.tooling)
    implementation(libs.compose.theme.adapter3)
    implementation(compose.webview)

    implementation(libs.flexbox)

    implementation(libs.material)

    // Android X libraries
    implementation(androidx.bundles.androidx)

    // ReactiveX
    implementation(libs.rxandroid)
    implementation(libs.rxjava)
    implementation(libs.rxrelay)

    // Chucker
    debugImplementation(libs.chucker.library)
    releaseImplementation(libs.chucker.library.no.op)

    implementation(kotlin("reflect", version = kotlinx.versions.kotlin.get()))

    // JSON
    implementation(kotlinx.bundles.serialization)

    // JavaScript engine
    implementation(libs.quickjs.android)

    // Disk
    implementation(libs.disklrucache)

    // HTML parser
    implementation(libs.jsoup)

    implementation(libs.play.services.gcm)

    // Database
    implementation(libs.sqlite.android)
    implementation(libs.bundles.sqlite)

    // Model View Presenter
    implementation(libs.conductor)
    implementation(libs.conductor.support.preference)

    // Image library
    implementation(platform(libs.coil3.bom))
    implementation(libs.bundles.coil)
    implementation(libs.subsamplingscaleimageview) {  // modified
        exclude(module = "image-decoder")
    }
    implementation(libs.image.decoder)

    // Sort
    implementation(libs.java.nat.sort)

    implementation(libs.aboutlibraries)

    // UI
    implementation(libs.fastadapter)
    implementation(libs.fastadapter.extensions.binding)
    implementation(libs.flexible.adapter)
    implementation(libs.flexible.adapter.ui)
    implementation(libs.viewstatepageradapter)
    implementation(libs.slice)
    implementation(libs.markwon)

    implementation(libs.photoview)
    implementation(libs.directionalviewpager)
    implementation(libs.viewtooltip)
    implementation(libs.taptargetview)

    // Navigation
    implementation(libs.bundles.voyager)

    // Shizuku
    implementation(libs.shizuku.api)
    implementation(libs.shizuku.provider)

    implementation(platform(kotlinx.coroutines.bom))
    implementation(kotlinx.bundles.coroutines)

    // TLS 1.3 support for Android < 10
    implementation(libs.conscrypt)

    // Android Chart
    implementation(libs.mpandroidchart)

    implementation(kotlinx.immutable)

    // Tests
    testImplementation(libs.bundles.test)
    testRuntimeOnly(libs.bundles.test.runtime)
    androidTestImplementation(libs.bundles.test.android)
    testImplementation(kotlinx.coroutines.test)

    // For detecting memory leaks
    // REF: https://square.github.io/leakcanary/
    debugImplementation(libs.leakcanary.android)
    implementation(libs.leakcanary.plumber)
}

// Code ported from other projects (not a Gradle dependency) is listed from these definitions.
aboutLibraries {
    collect {
        configPath = file("aboutlibraries")
    }
}

tasks {
    // See https://kotlinlang.org/docs/reference/experimental.html#experimental-status-of-experimental-api(-markers)
    withType<KotlinCompile> {
        compilerOptions.freeCompilerArgs.addAll(
            // "-opt-in=kotlin.Experimental",
            "-opt-in=kotlin.RequiresOptIn",
            "-opt-in=kotlin.ExperimentalStdlibApi",
            "-opt-in=coil3.annotation.ExperimentalCoilApi",
            "-opt-in=androidx.compose.foundation.layout.ExperimentalLayoutApi",
            "-opt-in=androidx.compose.material3.ExperimentalMaterial3Api",
            "-opt-in=androidx.compose.material3.ExperimentalMaterial3ExpressiveApi",
            "-opt-in=androidx.compose.ui.ExperimentalComposeUiApi",
            "-opt-in=androidx.compose.foundation.ExperimentalFoundationApi",
            "-opt-in=androidx.compose.animation.ExperimentalAnimationApi",
            // "-opt-in=com.google.accompanist.permissions.ExperimentalPermissionsApi",
            "-opt-in=kotlinx.coroutines.ExperimentalCoroutinesApi",
            "-opt-in=kotlinx.coroutines.FlowPreview",
            "-opt-in=kotlinx.coroutines.ExperimentalCoroutinesApi",
            "-opt-in=kotlinx.coroutines.InternalCoroutinesApi",
            "-opt-in=kotlinx.serialization.ExperimentalSerializationApi",
        )
    }

    // Duplicating Hebrew string assets due to some locale code issues on different devices
    val copyHebrewStrings = register("copyHebrewStrings", type = Copy::class) {
        from("./src/main/res/values-he")
        into("./src/main/res/values-iw")
        include("**/*")
    }

    preBuild {
        dependsOn(
            // formatKotlin,
            copyHebrewStrings
        )
    }
}
