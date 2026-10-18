plugins { alias(libs.plugins.android.library); alias(libs.plugins.kotlin.compose) }
android {
    namespace = "com.floe.android.design"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    buildFeatures { compose = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
dependencies {
    api(platform(libs.compose.bom))
    api(libs.compose.ui)
    api(libs.compose.foundation)
    api(libs.compose.material)
    // Explicit iOS-style substrate. Pages consume the Floe wrappers in this
    // module; raw Cupertino is kept out of feature code so the seam stays swappable.
    api(libs.cupertino)
    implementation(libs.androidx.activity.compose)
    testImplementation(libs.junit)
}
