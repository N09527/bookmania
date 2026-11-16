plugins { id("com.android.application") }
android {
    namespace = "dev.probe.webview"
    compileSdk = 36
    defaultConfig { applicationId = "dev.probe.webview"; minSdk = 26; targetSdk = 36; versionCode = 1; versionName = "1" }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    androidResources { noCompress += listOf("otf", "ttf") }
}
