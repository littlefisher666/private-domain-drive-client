allprojects {
    repositories {
        // From Maven settings-zkwlzz.xml mirror: zkwlzz maven (mirrorOf central)
        maven {
            name = "zkwlzz-maven-public"
            url = uri("https://nexus.zkwlzz.com/repository/maven-public/")
        }
        google()
        mavenCentral()
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

// file_picker 8.3.7 固定为 compileSdk 34，而当前 Flutter lifecycle AAR
// 要求依赖方至少使用 36。只提升编译 API，不改变应用 targetSdk/minSdk。
project(":file_picker") {
    afterEvaluate {
        extensions.configure<com.android.build.api.dsl.LibraryExtension> {
            compileSdk = 36
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
