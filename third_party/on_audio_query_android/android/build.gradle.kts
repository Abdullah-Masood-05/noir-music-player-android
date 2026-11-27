group = "com.lucasjosino.on_audio_query"
version = "1.0-SNAPSHOT"

// No Kotlin plugin is declared here on purpose (see NOIR_PATCH.md): Flutter's
// Gradle plugin supplies Kotlin to modules that don't declare it themselves.
plugins {
    id("com.android.library")
}

android {
    namespace = "com.lucasjosino.on_audio_query"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.7")
}
