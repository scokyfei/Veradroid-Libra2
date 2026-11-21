#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Build kobo-weread-opt.jar (DEX archive for WeRead 1.9.7 runtime optimizations:
# FontSizeCache, ReaderPageRelease, SegDictRelease).
# Usage:
#   ANDROID_JAR=/path/to/android.jar D8_JAR=/path/to/d8.jar sh tools/kobo/build-weread-opt.sh [OUT_JAR]
set -eu

TOP=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OUT=${1:-$TOP/build/kobo-bin/kobo-weread-opt.jar}
JAVA_HOME=${JAVA_HOME:-}
JAVAC=${JAVAC:-${JAVA_HOME:+$JAVA_HOME/bin/javac}}
JAVA=${JAVA:-${JAVA_HOME:+$JAVA_HOME/bin/java}}
[ -n "$JAVAC" ] || JAVAC=$(command -v javac)
[ -n "$JAVA" ] || JAVA=$(command -v java)
: "${ANDROID_JAR:?set ANDROID_JAR=/path/to/android.jar}"
: "${D8_JAR:?set D8_JAR=/path/to/d8.jar}"

TMP=$TOP/build/weread-opt-classes
rm -rf "$TMP"
mkdir -p "$TMP" "$(dirname "$OUT")"

"$JAVAC" --release 8 -cp "$ANDROID_JAR" -d "$TMP" "$TOP/tools/kobo/weread-opt/KoboWeReadOpt.java"
"$JAVA" -cp "$D8_JAR" com.android.tools.r8.D8 --min-api 25 --lib "$ANDROID_JAR" --output "$OUT" "$TMP"/*.class
ls -lh "$OUT"
