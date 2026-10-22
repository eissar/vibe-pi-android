plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

val ksFile = file(System.getenv("KEYSTORE") ?: "${System.getProperty("user.home")}/.config/vibe-pi-android/release.keystore")
val ksPassFile = file(System.getenv("KS_PASS_FILE") ?: "${System.getProperty("user.home")}/.config/vibe-pi-android/release.pass")

android {
    namespace = "dev.eissar.piagent"
    compileSdk = 34

    defaultConfig {
        applicationId = "dev.eissar.piagent"
        minSdk = 29
        targetSdk = 34
        versionCode = 5
        versionName = "0.5"
    }

    signingConfigs {
        create("release") {
            if (ksFile.exists()) {
                val pass = ksPassFile.readText().trim()
                storeFile = ksFile; storePassword = pass; keyPassword = pass
                keyAlias = System.getenv("KEY_ALIAS") ?: "release"
            } else {
                storeFile = rootProject.file("debug.keystore")
                storePassword = "android"; keyPassword = "android"; keyAlias = "androiddebugkey"
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName("release")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    dependenciesInfo { includeInApk = false; includeInBundle = false } // F-Droid
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.icons)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.okhttp)
    implementation(libs.markdown.m3)
    implementation(libs.markdown.code)
    implementation(libs.serialization.json)
    implementation(libs.coroutines.android)
    implementation(libs.lifecycle.runtime.compose)
}
