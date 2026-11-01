# The embedded server is started by app_process using its class name, so R8
# must not rename or remove this entry point or its service implementation.
-keep class com.floe.android.rootsystem.server.FloeSystemServer {
    public static void main(java.lang.String[]);
}
-keep class com.floe.android.rootsystem.server.** { *; }
-keep class com.floe.android.rootsystem.ipc.IFloeSystemService { *; }
-keep class com.floe.android.rootsystem.ipc.IFloeSystemService$Stub { *; }
-keep class com.floe.android.rootsystem.ipc.FloeSystemProvider { *; }

# Native pairing declarations are registered with RegisterNatives by signature.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
