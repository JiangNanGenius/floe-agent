// Source-only qualification host; outputs use the checkout's managed cache.
val outRoot = java.io.File(requireNotNull(System.getenv("FLOE_ANDROID_BUILD_ROOT")) {
    "Source FloeAndroid/scripts/env.sh before building this host"
}, "linuxruntime-qualification")
allprojects {
    layout.buildDirectory.set(outRoot.resolve(project.path.removePrefix(":").replace(':', '/')))
}
