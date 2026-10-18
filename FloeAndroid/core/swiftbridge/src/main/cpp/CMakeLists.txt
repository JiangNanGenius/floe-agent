cmake_minimum_required(VERSION 3.22.1)
project(floe_android_bridge LANGUAGES CXX)
add_library(FloeAndroidCore SHARED IMPORTED)
set_target_properties(FloeAndroidCore PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libFloeAndroidCore.so"
    IMPORTED_NO_SONAME TRUE)
add_library(floe_jni SHARED floe_jni.cpp)
target_link_libraries(floe_jni PRIVATE FloeAndroidCore)
target_link_options(floe_jni PRIVATE "-Wl,-z,max-page-size=16384")
