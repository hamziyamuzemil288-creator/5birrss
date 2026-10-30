plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.amistbirr.myapp"
    compileSdk = 36
    // Pinned to the version every Flutter plugin here declares (app_links,
    // firebase_core, firebase_messaging, flutter_local_notifications, ...).
    // `flutter.ndkVersion` happens to resolve to this today, but it floats
    // with whatever Flutter release CI installs, and AGP fails the build when
    // a plugin needs a newer NDK than the project names. Naming it keeps the
    // declaration and the plugins in step. CI pre-installs this NDK so the
    // build never downloads it mid-run (see .github/workflows/flutter-ci.yml).
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications (>= 10) schedules with java.time, which
        // only exists natively on API 26+. Core library desugaring backports
        // those APIs so the plugin works down to minSdk; without this flag the
        // release build fails at :app:checkReleaseAarMetadata with
        // "Dependency ':flutter_local_notifications' requires core library
        // desugaring to be enabled for :app".
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // Fixed by owner decision. Google locks the applicationId permanently
        // on first upload, so changing it later means shipping a new app.
        applicationId = "com.amistbirr.myapp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        // Pinned deliberately. `flutter.targetSdkVersion` floats with the
        // Flutter SDK the CI runner happens to install, and Google Play
        // hard-rejects uploads below target API 35. A submission gate should
        // not depend on which Flutter version a runner pulls that week.
        // Bump this deliberately, alongside compileSdk above.
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = file(System.getenv("KEYSTORE_PATH") ?: "release-keystore.p12")
            storePassword = System.getenv("KEYSTORE_PASSWORD") ?: ""
            keyAlias = System.getenv("KEY_ALIAS") ?: "fivebirr"
            keyPassword = System.getenv("KEY_PASSWORD") ?: ""
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Paired with isCoreLibraryDesugaringEnabled above. 2.1.4 is the version
    // the flutter_local_notifications setup docs call for on modern AGP; it
    // must be the ONLY desugar_jdk_libs on the classpath.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
