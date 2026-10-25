# The prebuilt libandroidapp.so resolves its JNI exports and FindClass targets
# by the exact upstream names. These classes must survive shrinking/obfuscation
# in any consuming App build (core ABI authority, not an optimization choice).
-keep class org.libreoffice.androidlib.LOActivity { *; }
-keep class org.libreoffice.androidlib.COWebViewClient { *; }
-keep class org.libreoffice.androidlib.lok.LokClipboardData { *; }
-keep class org.libreoffice.androidlib.lok.LokClipboardEntry { *; }
