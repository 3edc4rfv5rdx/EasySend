# flutter_local_notifications deserializes its scheduling data through Gson,
# so its model classes must survive shrinking.
-keep class com.dexterous.** { *; }
-keepattributes *Annotation*
-keepattributes Signature

# Gson's reflective type resolution.
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken

# Our own service and activity are only referenced from the manifest.
-keep class a.a.easysend.** { *; }
