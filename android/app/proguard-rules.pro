# AndroidX Startup & WorkManager Initializer
-keep class androidx.startup.** { *; }
-keep class androidx.work.WorkManagerInitializer {
    public <init>();
    *;
}

# AndroidX WorkManager (Keep all classes, InputMergers, DAOs, Workers and reflective constructors)
-keep class androidx.work.** { *; }
-keep interface androidx.work.** { *; }

# AndroidX Room & WorkDatabase (Prevents R8 full mode from stripping WorkDatabase_Impl.<init>())
-keep class * extends androidx.room.RoomDatabase {
    public <init>();
    *;
}
-keep @androidx.room.Database class * {
    public <init>();
    *;
}
-keep class androidx.room.Room { *; }
-keep class androidx.work.impl.WorkDatabase {
    public <init>();
    *;
}
-keep class androidx.work.impl.WorkDatabase_Impl {
    public <init>();
    *;
}
-keep class androidx.work.impl.model.** { *; }

# AndroidX WorkManager Workers
-keep class * extends androidx.work.ListenableWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
    *;
}
-keep class * extends androidx.work.CoroutineWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
    *;
}

# JessFlix Native Classes (MainActivity & OtaDownloadWorker)
-keep class com.player.m3u.projeto_tv.MainActivity {
    public <init>();
    *;
}
-keep class com.player.m3u.projeto_tv.OtaDownloadWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
    *;
}

# Optional Play Core classes not used on Fire TV / direct APK builds
-dontwarn com.google.android.play.core.**
