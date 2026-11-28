plugins {
    id("yokai.android.library")
    kotlin("android")
    alias(kotlinx.plugins.serialization)
}

android {
    namespace = "yokai.core.sync"
}

dependencies {
    implementation(kotlinx.serialization.json)
    implementation(libs.okhttp)
    // The app's Okio (OkHttp asks for an older one).
    implementation(libs.okio)

    testImplementation(libs.bundles.test)
    testRuntimeOnly(libs.bundles.test.runtime)
}
