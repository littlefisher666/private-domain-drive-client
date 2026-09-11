import org.gradle.api.artifacts.dsl.RepositoryHandler
import org.gradle.api.artifacts.repositories.MavenArtifactRepository

pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        maven {
            name = "aliyun-gradle-plugin"
            url = uri("https://maven.aliyun.com/repository/gradle-plugin")
        }
        maven {
            name = "aliyun-google"
            url = uri("https://maven.aliyun.com/repository/google")
        }
        maven {
            name = "aliyun-public"
            url = uri("https://maven.aliyun.com/repository/public")
        }
    }
}

private fun RepositoryHandler.useAliyunMavenMirrors() {
    withType(MavenArtifactRepository::class.java).configureEach {
        val source = url.toString().removeSuffix("/")
        url = when (source) {
            "https://dl.google.com/dl/android/maven2" ->
                uri("https://maven.aliyun.com/repository/google")
            "https://repo.maven.apache.org/maven2" ->
                uri("https://maven.aliyun.com/repository/public")
            "https://plugins.gradle.org/m2" ->
                uri("https://maven.aliyun.com/repository/gradle-plugin")
            else -> url
        }
    }
}

// Flutter 插件会在各自的 build.gradle 中声明 google()/mavenCentral()。
// 在项目求值前重写这些仓库，避免插件绕过根项目的镜像配置。
gradle.beforeProject {
    buildscript.repositories.useAliyunMavenMirrors()
    repositories.useAliyunMavenMirrors()
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
