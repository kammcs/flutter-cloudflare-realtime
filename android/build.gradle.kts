group = "dev.kammcs.cloudflare_realtime"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

// Kotlin. AGP 9's built-in Kotlin compiles the plugin's Kotlin sources and
// rejects the Kotlin Gradle plugin; older AGP versions (the Android
// templates of Flutter releases before AGP 9) need that plugin. So apply it
// only when built-in Kotlin isn't active: AGP 8, or AGP 9 with
// `android.builtInKotlin=false`. flutter_webrtc uses the same rule.
val agpMajorVersion =
    com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.substringBefore('.').toInt()
val builtInKotlin =
    agpMajorVersion >= 9 &&
        (findProperty("android.builtInKotlin")?.toString()?.toBoolean() ?: true)
if (!builtInKotlin) {
    apply(plugin = "org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.kammcs.cloudflare_realtime"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        // JVM unit tests of the pure Kotlin (no device): from example/android,
        // `./gradlew :cloudflare_realtime:testDebugUnitTest`.
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }
}

dependencies {
    // System calls on Android (docs/design.md §4.8): Jetpack Core-Telecom
    // (Apache-2.0) and the coroutines its API is built on.
    implementation("androidx.core:core-telecom:1.0.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("junit:junit:4.13.2")
}

// The type-safe `kotlin { }` accessor isn't generated for a plugin applied
// with `apply(...)`, so set the JVM target on the compile tasks, which works
// either way.
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile>().configureEach {
    compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
}
