import java.util.Properties
import java.util.Base64

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val dartDefines = providers.gradleProperty("dart-defines").orNull.orEmpty()
    .split(",").filter { it.isNotEmpty() }
    .associate {
        val decoded = String(Base64.getDecoder().decode(it), Charsets.UTF_8)
        decoded.substringBefore("=") to decoded.substringAfter("=", "")
    }
val allSources = dartDefines["ALL_SOURCES"] == "true"
val android6Compatibility = dartDefines["ANDROID6_COMPAT"] == "true"
val editionLabel = if (allSources) "真果鉴" else "红果鉴"
val appLabel = editionLabel + if (android6Compatibility) "兼容版" else ""
val appId = when {
    android6Compatibility -> "com.duanju.duanju_app.android6"
    allSources -> "com.duanju.duanju_app.zhenguojian"
    else -> "com.duanju.duanju_app"
}

val releaseKey = rootProject.file("key.properties")
val releaseProperties = Properties()
if (releaseKey.exists()) {
    releaseKey.inputStream().use { releaseProperties.load(it) }
}

android {
    namespace = "com.duanju.duanju_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = appId
        minSdk = if (android6Compatibility) 23 else 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        manifestPlaceholders["appBuildNumber"] = flutter.versionCode.toString()
        versionName = flutter.versionName
        manifestPlaceholders["appLabel"] = appLabel
        manifestPlaceholders["appLabelFull"] = appLabel
        manifestPlaceholders["appIcon"] =
            if (allSources) "@mipmap/ic_launcher_full" else "@drawable/app_icon"
        manifestPlaceholders["appBanner"] = if (allSources) "@drawable/tv_banner_all_sources" else "@drawable/tv_banner"
        manifestPlaceholders["appBannerFull"] = if (allSources) "@drawable/tv_banner_all_sources" else "@drawable/tv_banner"
    }

    signingConfigs {
        getByName("debug") {
            enableV1Signing = true
            enableV2Signing = true
        }
        if (releaseKey.exists()) {
            create("release") {
                storeFile = file(requireNotNull(releaseProperties.getProperty("storeFile")))
                storePassword = requireNotNull(releaseProperties.getProperty("storePassword"))
                keyAlias = requireNotNull(releaseProperties.getProperty("keyAlias"))
                keyPassword = requireNotNull(releaseProperties.getProperty("keyPassword"))
                storeType = releaseProperties.getProperty("storeType") ?: "JKS"
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
        }
        release {
            signingConfig = signingConfigs.getByName(if (releaseKey.exists()) "release" else "debug")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter { source = "../.." }

tasks.withType<JavaCompile>().configureEach {
    if (name.contains("Release")) {
        doFirst {
            val registrant = file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java")
            if (registrant.exists()) {
                val generated = registrant.readText()
                val integrationPlugin = Regex(
                    """(?s)    try \{\s*flutterEngine\.getPlugins\(\)\.add\(new dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin\(\)\);\s*\} catch \(Exception e\) \{[^}]*\}\s*"""
                )
                val release = generated.replace(integrationPlugin, "")
                if (release != generated) registrant.writeText(release)
            }
        }
    }
}
