#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Build VeraHome.apk from android/packages/VeraHome/ using JDK 17 + android.jar + d8 + aapt2 + apksigner,
# signed with the AOSP standard platform test key so it drops straight into /system/priv-app/VeraHome/.
#
# Environment:
#   TOOLS_DIR  Directory containing jdk17/, android/{android.jar,d8.jar,aapt2,apksigner.jar}, keys/platform.{pk8,x509.pem}
#   OUT_APK    Output APK path (default: build/kobo-bin/VeraHome.apk)
set -eu

TOP=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TOOLS_DIR=${TOOLS_DIR:-$TOP/build/tools}
JDK=${JDK:-$TOOLS_DIR/jdk17/Contents/Home}
[ -x "$JDK/bin/javac" ] || JDK=${JAVA_HOME:-/usr}
JAVAC=$JDK/bin/javac
JAVA=$JDK/bin/java
JAR=$JDK/bin/jar

ANDROID_JAR=${ANDROID_JAR:-$TOOLS_DIR/android/android.jar}
D8_JAR=${D8_JAR:-$TOOLS_DIR/android/d8.jar}
AAPT2=${AAPT2:-$TOOLS_DIR/android/aapt2}
APKSIGNER_JAR=${APKSIGNER_JAR:-$TOOLS_DIR/android/apksigner.jar}
KEY_PK8=${KEY_PK8:-$TOOLS_DIR/keys/platform.pk8}
KEY_PEM=${KEY_PEM:-$TOOLS_DIR/keys/platform.x509.pem}

SRC_DIR=$TOP/android/packages/VeraHome
OUT_APK=${OUT_APK:-$TOP/build/kobo-bin/VeraHome.apk}
WORK=$TOP/build/verahome-work

for f in "$ANDROID_JAR" "$D8_JAR" "$AAPT2" "$APKSIGNER_JAR" "$KEY_PK8" "$KEY_PEM"; do
    [ -e "$f" ] || { echo "build-verahome: missing $f" >&2; exit 2; }
done

rm -rf "$WORK"
mkdir -p "$WORK/stubs-src" "$WORK/stubs-cls" "$WORK/cls" "$WORK/dex" "$(dirname "$OUT_APK")"

# 1. Generate minimal compile-only AOSP 7.1 hidden API stubs (never packaged into classes.dex)
mkdir -p "$WORK/stubs-src/android/app" "$WORK/stubs-src/android/content/pm" "$WORK/stubs-src/android/hardware/input"

cat > "$WORK/stubs-src/android/app/ITaskStackListener.java" <<'EOF'
package android.app;
import android.os.Binder;
import android.os.IBinder;
import android.os.IInterface;
public interface ITaskStackListener extends IInterface {
    void onTaskStackChanged();
    void onActivityPinned();
    void onPinnedActivityRestartAttempt();
    void onPinnedStackAnimationEnded();
    void onActivityForcedResizable(String packageName, int taskId);
    void onActivityDismissingDockedStack();
    abstract class Stub extends Binder implements ITaskStackListener {
        @Override public IBinder asBinder() { return this; }
    }
}
EOF

cat > "$WORK/stubs-src/android/app/IActivityManager.java" <<'EOF'
package android.app;
import android.os.RemoteException;
public interface IActivityManager {
    void registerTaskStackListener(ITaskStackListener listener) throws RemoteException;
}
EOF

cat > "$WORK/stubs-src/android/app/ActivityManagerNative.java" <<'EOF'
package android.app;
public abstract class ActivityManagerNative {
    public static IActivityManager getDefault() { return null; }
}
EOF

cat > "$WORK/stubs-src/android/content/pm/IPackageDataObserver.java" <<'EOF'
package android.content.pm;
import android.os.Binder;
import android.os.IBinder;
import android.os.IInterface;
public interface IPackageDataObserver extends IInterface {
    void onRemoveCompleted(String packageName, boolean succeeded);
    abstract class Stub extends Binder implements IPackageDataObserver {
        @Override public IBinder asBinder() { return this; }
    }
}
EOF

cat > "$WORK/stubs-src/android/content/pm/PackageStats.java" <<'EOF'
package android.content.pm;
public class PackageStats {
    public String packageName;
    public long codeSize, dataSize, cacheSize;
    public long externalCodeSize, externalDataSize, externalCacheSize, externalMediaSize, externalObbSize;
}
EOF

cat > "$WORK/stubs-src/android/content/pm/IPackageStatsObserver.java" <<'EOF'
package android.content.pm;
import android.os.Binder;
import android.os.IBinder;
import android.os.IInterface;
public interface IPackageStatsObserver extends IInterface {
    void onGetStatsCompleted(PackageStats pStats, boolean succeeded);
    abstract class Stub extends Binder implements IPackageStatsObserver {
        @Override public IBinder asBinder() { return this; }
    }
}
EOF

echo "[1/5] Compiling hidden API stubs ..."
find "$WORK/stubs-src" -name '*.java' > "$WORK/stubs.list"
"$JAVAC" -source 8 -target 8 -encoding UTF-8 -Xlint:none \
    -bootclasspath "$ANDROID_JAR" \
    -d "$WORK/stubs-cls" @"$WORK/stubs.list"

echo "[2/5] Compiling VeraHome Java sources ..."
find "$SRC_DIR/src" -name '*.java' | sort > "$WORK/src.list"
"$JAVAC" -source 8 -target 8 -encoding UTF-8 -Xlint:none \
    -bootclasspath "$WORK/stubs-cls:$ANDROID_JAR" \
    -d "$WORK/cls" @"$WORK/src.list"

echo "[3/5] Converting bytecode to classes.dex via d8 ..."
find "$WORK/cls" -name '*.class' > "$WORK/cls.list"
"$JAVA" -Xmx512m -cp "$D8_JAR" com.android.tools.r8.D8 \
    --release --min-api 25 \
    --lib "$ANDROID_JAR" \
    --output "$WORK/dex" \
    @"$WORK/cls.list"

echo "[4/5] Packaging APK with aapt2 (AndroidManifest.xml + assets + classes.dex) ..."
"$AAPT2" link \
    -o "$WORK/unsigned.apk" \
    -I "$ANDROID_JAR" \
    --manifest "$SRC_DIR/AndroidManifest.xml" \
    -A "$SRC_DIR/assets" \
    --min-sdk-version 25 \
    --target-sdk-version 25 \
    --auto-add-overlay

(cd "$WORK/dex" && zip -q -0 "$WORK/unsigned.apk" classes.dex)

echo "[5/5] Signing APK with AOSP platform test key ..."
"$JAVA" -Xmx256m -jar "$APKSIGNER_JAR" sign \
    --key "$KEY_PK8" \
    --cert "$KEY_PEM" \
    --v1-signing-enabled true \
    --v2-signing-enabled true \
    --out "$OUT_APK" \
    "$WORK/unsigned.apk"

"$JAVA" -Xmx256m -jar "$APKSIGNER_JAR" verify --print-certs "$OUT_APK"
ls -lh "$OUT_APK"
