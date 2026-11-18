plugins {
    id("yokai.android.library")
    kotlin("android")
}

android {
    namespace = "yokai.core.ebook"
}

dependencies {
    implementation(libs.jsoup)

    testImplementation(libs.bundles.test)
    testRuntimeOnly(libs.bundles.test.runtime)
}
