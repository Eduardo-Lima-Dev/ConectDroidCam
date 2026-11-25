import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val keyProperties = Properties().apply {
    val arquivo = rootProject.file("key.properties")
    if (arquivo.exists()) arquivo.inputStream().use { load(it) }
}

fun assinatura(variavel: String, propriedade: String): String? =
    System.getenv(variavel)?.takeIf { it.isNotBlank() } ?: keyProperties.getProperty(propriedade)

val keystoreDeRelease: String? = assinatura("ANDROID_KEYSTORE_PATH", "storeFile")

android {
    namespace = "dev.eduardolima.conectdroidcam"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.eduardolima.conectdroidcam"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystoreDeRelease != null) {
            create("release") {
                storeFile = file(keystoreDeRelease)
                storePassword = assinatura("ANDROID_KEYSTORE_PASSWORD", "storePassword")
                keyAlias = assinatura("ANDROID_KEY_ALIAS", "keyAlias")
                keyPassword = assinatura("ANDROID_KEY_PASSWORD", "keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystoreDeRelease != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.work:work-runtime:2.10.1")
}
