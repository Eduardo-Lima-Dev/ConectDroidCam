import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Chave de release: no CI vem das variáveis de ambiente (segredos do GitHub); na máquina de
// desenvolvimento, de android/key.properties (fora do git). Sem nenhum dos dois, o release usa
// a chave de debug, para PRs e builds locais continuarem funcionando. O Android só atualiza o
// app se a versão nova tiver a mesma assinatura da instalada, então releases publicados
// precisam sempre da mesma chave.
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
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.eduardolima.conectdroidcam"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
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
