allprojects {
    repositories {
        // 与 settings.gradle.kts 保持一致：CI 直连默认仓库，本地走阿里云镜像。
        if (System.getenv("CI")?.toBooleanStrictOrNull() != true) {
            maven {
                name = "aliyun-google"
                url = uri("https://maven.aliyun.com/repository/google")
            }
            maven {
                name = "aliyun-public"
                url = uri("https://maven.aliyun.com/repository/public")
            }
        } else {
            google()
            mavenCentral()
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
