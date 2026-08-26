allprojects {
    repositories {
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

subprojects {
    // Has to run after the module configures itself: `plugins.withId` fires
    // when the plugin is applied, which is *before* the module's own
    // `android { compileOptions }` block, so a plugin that pins Java 11
    // (rive_native does) would win and then clash with the Kotlin tasks forced
    // to 17 below, failing the build.
    val alignJavaTarget = {
        val androidExtension = extensions.findByName("android")
        if (androidExtension is com.android.build.gradle.BaseExtension) {
            androidExtension.compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
        }
    }
    // `evaluationDependsOn(":app")` above already forced :app through
    // evaluation; afterEvaluate throws on those and their compileOptions are
    // finalized anyway. :app sets Java 17 itself, so skipping them is correct.
    if (!state.executed) afterEvaluate { alignJavaTarget() }

    tasks.configureEach {
        if (name.contains("compile") && name.contains("Kotlin")) {
            try {
                val kotlinOptions = property("kotlinOptions")
                val method = kotlinOptions?.javaClass?.getMethod("setJvmTarget", String::class.java)
                method?.invoke(kotlinOptions, "17")
            } catch (e: Exception) {
                // Ignore
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
