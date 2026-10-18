plugins { alias(libs.plugins.android.library) }
android {
    namespace = "com.floe.android.phonecontrol"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
}
dependencies { implementation(project(":core:contracts")) }
