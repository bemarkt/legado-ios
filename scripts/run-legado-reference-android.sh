#!/usr/bin/env bash
set -euo pipefail
# Invoked at the repository root while the CI emulator is alive.
mkdir -p build/legado-compatibility
collect_evidence() {
  if adb exec-out run-as com.legado.app.debug cat files/legado-compatibility-android.json > build/legado-compatibility/android.json.tmp; then
    mv build/legado-compatibility/android.json.tmp build/legado-compatibility/android.json
  fi
  adb logcat -d > build/legado-compatibility/android-logcat.log || true
}
trap collect_evidence EXIT
build/android-reference/checkout/gradlew -p build/android-reference/checkout \
  :app:connectedAppDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=io.legado.app.compatibility.LegadoDifferentialTest \
  --no-daemon --max-workers=2 -Dorg.gradle.jvmargs="-Xmx4g -Dfile.encoding=UTF-8" \
  2>&1 | tee build/legado-compatibility/android-test.log
