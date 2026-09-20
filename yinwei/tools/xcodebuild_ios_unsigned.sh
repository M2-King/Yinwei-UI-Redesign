#!/usr/bin/env bash
# Unsigned iphoneos xcodebuild for CI. Does not modify DSP/HRTF/audio.
#
# Usage:
#   ./yinwei/tools/xcodebuild_ios_unsigned.sh <ios_dir> <derived_data_directory>
set -euo pipefail

IOS_DIR="${1:?ios directory}"
DERIVED="${2:?derived data directory}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YINWEI_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVICE_A="$YINWEI_ROOT/target/aarch64-apple-ios/release/libspatial_core.a"
XCFRAMEWORK="$IOS_DIR/Native/libspatial_core.xcframework"
PBX="$IOS_DIR/Runner.xcodeproj/project.pbxproj"
KEEP_C="$IOS_DIR/Runner/spatial_core_ffi_keep.c"
LOG_DIR="${XCODEBUILD_LOG_DIR:-/tmp/xcodebuild_logs}"
mkdir -p "$LOG_DIR" "$DERIVED"
LOG="$LOG_DIR/xcodebuild-unsigned.log"
SETTINGS_LOG="$LOG_DIR/runner-show-build-settings.log"

if [[ ! -f "$DEVICE_A" ]]; then
  echo "ERROR: missing $DEVICE_A" >&2
  echo "Run tools/build_native_ios.sh so libspatial_core.a exists, then rebuild." >&2
  exit 1
fi
if [[ ! -d "$XCFRAMEWORK" ]]; then
  echo "ERROR: missing $XCFRAMEWORK" >&2
  echo "Run tools/build_native_ios.sh so the xcframework is in Runner Frameworks." >&2
  exit 1
fi
if [[ ! -f "$KEEP_C" ]]; then
  echo "ERROR: missing $KEEP_C" >&2
  exit 1
fi
if ! grep -q "libspatial_core.xcframework in Frameworks" "$PBX"; then
  echo "ERROR: Runner Frameworks phase does not link libspatial_core.xcframework" >&2
  exit 1
fi
if ! grep -q '"_yinwei_open"' "$PBX"; then
  echo "ERROR: Runner OTHER_LDFLAGS is missing literal -u _yinwei_open" >&2
  exit 1
fi
if grep -q 'SPATIAL_CORE_FORCE_LDFLAGS' "$PBX"; then
  echo "ERROR: nested SPATIAL_CORE_FORCE_LDFLAGS must not be used for Runner OTHER_LDFLAGS" >&2
  exit 1
fi

echo "===== spatial_core artifacts ====="
echo "DEVICE_A=$DEVICE_A"
ls -la "$DEVICE_A"
echo "XCFRAMEWORK=$XCFRAMEWORK"
ls -la "$XCFRAMEWORK"
echo "===== end spatial_core artifacts ====="

cd "$IOS_DIR"

python3 "$SCRIPT_DIR/patch_ios_file_picker_no_dkcamera.py" \
  "$IOS_DIR" \
  "$IOS_DIR/Flutter/ephemeral" \
  "$DERIVED" \
  || true

dump_runner_resolved_settings() {
  echo "===== xcodebuild -showBuildSettings (Runner) ====="
  # shellcheck disable=SC2046
  xcodebuild \
    -workspace Runner.xcworkspace \
    -scheme Runner \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY=- \
    STRIP_INSTALLED_PRODUCT=NO \
    STRIP_STYLE=non-global \
    ENABLE_DEBUG_DYLIB=NO \
    -showBuildSettings \
    >"$SETTINGS_LOG" 2>"$LOG_DIR/runner-show-build-settings.err" || {
      echo "ERROR: xcodebuild -showBuildSettings failed" >&2
      cat "$LOG_DIR/runner-show-build-settings.err" >&2 || true
      exit 1
    }

  python3 - "$SETTINGS_LOG" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8", errors="replace").read()
blocks = re.split(r"(?=Build settings for action )", text)
runner = next((b for b in blocks if re.search(r"target Runner:\s*$", b, re.M)), None)
if runner is None:
    runner = next((b for b in blocks if "target Runner:" in b and "RunnerTests" not in b.split("\n", 1)[0]), None)
if runner is None:
    print("ERROR: could not isolate Runner target build settings", file=sys.stderr)
    sys.exit(1)
keys = (
    "OTHER_LDFLAGS",
    "SPATIAL_CORE_FORCE_LDFLAGS",
    "SPATIAL_CORE_LIB",
    "STRIP_INSTALLED_PRODUCT",
    "STRIP_STYLE",
    "DEAD_CODE_STRIPPING",
    "PRODUCT_NAME",
    "TARGET_NAME",
    "TARGET_BUILD_DIR",
    "CONFIGURATION_BUILD_DIR",
    "EXECUTABLE_PATH",
    "SDKROOT",
    "ENABLE_DEBUG_DYLIB",
)
print(runner.splitlines()[0])
lines = runner.splitlines()
i = 0
while i < len(lines):
    stripped = lines[i].strip()
    matched = next((key for key in keys if stripped.startswith(key + " =") or stripped.startswith(key + "=")), None)
    if matched:
        print(lines[i].rstrip())
        if stripped.endswith("("):
            i += 1
            while i < len(lines):
                print(lines[i].rstrip())
                if lines[i].strip().startswith(")"):
                    break
                i += 1
    i += 1
if "_yinwei_open" not in runner:
    print("ERROR: resolved Runner OTHER_LDFLAGS does not contain _yinwei_open", file=sys.stderr)
    sys.exit(1)
if "force_load" not in runner:
    print("ERROR: resolved Runner OTHER_LDFLAGS does not contain force_load", file=sys.stderr)
    sys.exit(1)
if not re.search(r"ENABLE_DEBUG_DYLIB\s*=\s*NO\b", runner):
    print("ERROR: ENABLE_DEBUG_DYLIB must be NO so Runner.app/Runner is the FFI binary, not a debug stub", file=sys.stderr)
    sys.exit(1)
print("PROOF: resolved Runner settings contain _yinwei_open, force_load, ENABLE_DEBUG_DYLIB=NO")
PY
  echo "===== end Runner resolved settings ====="
}

extract_ld_runner() {
  echo "===== Ld Runner (from xcodebuild log) ====="
  if [[ ! -f "$LOG" ]]; then
    echo "ERROR: missing $LOG" >&2
    return 1
  fi
  python3 - "$LOG" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
hits = []
for i, line in enumerate(text):
    if re.search(r"\bLd\b.*Runner(\.app/Runner)?\b", line) and "RunnerTests" not in line:
        chunk = text[i:min(i + 12, len(text))]
        blob = "\n".join(chunk)
        if "ExecutorLinkFileList" in blob or "debug_blank_executor" in blob:
            continue
        hits.append(blob)
if not hits:
    # Xcode 16 sometimes prints the clang driver line without a leading Ld token.
    for i, line in enumerate(text):
        if "Runner.app/Runner" in line and ("bin/clang" in line or "bin/ld" in line):
            blob = "\n".join(text[i:min(i + 8, len(text))])
            if "ExecutorLinkFileList" in blob or "debug_blank_executor" in blob:
                continue
            hits.append(blob)
            break
if not hits:
    print("WARNING: could not find an Ld Runner invocation in the xcodebuild log")
    sys.exit(0)
print(hits[-1])
blob = hits[-1]
for token in ("libspatial_core", "force_load", "-u", "_yinwei_open"):
    status = "YES" if token in blob else "NO"
    print(f"Ld contains {token}: {status}")
PY
  echo "===== end Ld Runner ====="
  echo "===== derived-data spatial_core references ====="
  grep -R -l "libspatial_core" "$DERIVED/Build/Intermediates.noindex" 2>/dev/null | awk 'NR<=20 {print}' || true
  echo "===== end derived-data spatial_core references ====="
}

verify_built_runner_ffi() {
  echo "===== compile evidence: spatial_core_ffi_keep.c ====="
  if [[ -f "$LOG" ]]; then
    grep -n "spatial_core_ffi_keep.c" "$LOG" | awk 'NR<=40 {print}' || echo "WARNING: keep.c not mentioned in xcodebuild log"
  fi
  echo "===== end compile evidence ====="
  echo "===== Runner.app candidates ====="
  local player_dir
  player_dir="$(cd "$IOS_DIR/.." && pwd)"
  find "$player_dir/build" "$DERIVED" -name Runner.app -type d 2>/dev/null | while IFS= read -r p; do
    echo "$p"
    if [[ -f "$p/Runner" ]]; then
      hits="$(nm "$p/Runner" 2>/dev/null | grep -i yinwei || true)"
      if [[ -n "$hits" ]]; then
        printf '%s\n' "$hits" | awk 'NR<=8 {print}'
      else
        echo "  (no yinwei symbols)"
      fi
      if [[ -f "$p/Runner.debug.dylib" ]]; then
        echo "  WARNING: Runner.debug.dylib present; Dart FFI must be in Runner.app/Runner"
        dylib_hits="$(nm "$p/Runner.debug.dylib" 2>/dev/null | grep -i yinwei || true)"
        if [[ -n "$dylib_hits" ]]; then
          printf '%s\n' "$dylib_hits" | awk 'NR<=8 {print}'
        else
          echo "  (no yinwei in debug dylib)"
        fi
      fi
    else
      echo "  (missing Runner executable)"
    fi
  done
  echo "===== end Runner.app candidates ====="

  python3 - "$SETTINGS_LOG" "$LOG_DIR/runner-app-path.txt" "$SCRIPT_DIR/verify_ios_ffi.sh" "$DERIVED" <<'PY'
import os, re, subprocess, sys
settings_path, out_path, verifier = sys.argv[1], sys.argv[2], sys.argv[3]
derived = sys.argv[4] if len(sys.argv) > 4 else ""
text = open(settings_path, encoding="utf-8", errors="replace").read()
blocks = re.split(r"(?=Build settings for action )", text)
runner = next((b for b in blocks if re.search(r"target Runner:\s*$", b, re.M)), None)
if runner is None:
    runner = next((b for b in blocks if "target Runner:" in b and "RunnerTests" not in b.split("\n", 1)[0]), None)
if runner is None:
    print("ERROR: could not isolate Runner target build settings", file=sys.stderr)
    sys.exit(1)

def setting(name):
    m = re.search(r"^\s*" + re.escape(name) + r"\s*=\s*(.+?)\s*$", runner, re.M)
    return m.group(1) if m else ""

def nm_text(path):
    return subprocess.run(["nm", path], capture_output=True, text=True).stdout

def yinwei_lines(path):
    return [ln for ln in nm_text(path).splitlines() if "yinwei" in ln.lower()]

def is_debug_stub(path):
    return "___debug_blank_executor_main" in nm_text(path)

target_dir = setting("TARGET_BUILD_DIR")
exec_path = setting("EXECUTABLE_PATH") or "Runner.app/Runner"
print(f"TARGET_BUILD_DIR={target_dir}")
print(f"EXECUTABLE_PATH={exec_path}")
candidates = []
if target_dir:
    candidates.append(os.path.join(target_dir, exec_path))
if derived:
    candidates.append(os.path.join(derived, "Build/Products/Release-iphoneos/Runner.app/Runner"))
seen = set()
chosen = None
chosen_hits = []
for binary in candidates:
    if not binary or binary in seen:
        continue
    seen.add(binary)
    print(f"CANDIDATE {binary}")
    if not os.path.isfile(binary):
        print("  missing")
        continue
    if is_debug_stub(binary):
        print("  REJECT Xcode 16 debug-dylib stub (___debug_blank_executor_main)")
        dylib = os.path.join(os.path.dirname(binary), "Runner.debug.dylib")
        print(f"===== nm yinwei {dylib} (diagnostic only) =====")
        if os.path.isfile(dylib):
            hits = yinwei_lines(dylib)
            print("\n".join(hits) if hits else "(none)")
        else:
            print("(missing)")
        continue
    hits = yinwei_lines(binary)
    print("===== nm yinwei =====")
    print("\n".join(hits) if hits else "(none)")
    if hits and chosen is None:
        chosen, chosen_hits = binary, hits
if chosen is None:
    print("ERROR: no xcodebuild Runner product contains yinwei_* symbols", file=sys.stderr)
    print("ERROR: ENABLE_DEBUG_DYLIB must be NO so Dart process() sees FFI in Runner.app/Runner", file=sys.stderr)
    sys.exit(1)
print(f"PROOF: {len(chosen_hits)} yinwei nm lines in {chosen}")
open(out_path, "w", encoding="utf-8").write(os.path.dirname(chosen) + "\n")
raise SystemExit(subprocess.call(["bash", verifier, chosen]))
PY
}

run_unsigned_xcodebuild() {
  xcodebuild \
    -workspace Runner.xcworkspace \
    -scheme Runner \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY=- \
    EXPANDED_CODE_SIGN_IDENTITY=- \
    SWIFT_OPTIMIZATION_LEVEL=-Onone \
    SWIFT_COMPILATION_MODE=incremental \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    _EXPERIMENTAL_SWIFT_EXPLICIT_MODULES=NO \
    SWIFT_EMIT_MODULE_INTERFACE=NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    STRIP_INSTALLED_PRODUCT=NO \
    STRIP_STYLE=non-global \
    ENABLE_DEBUG_DYLIB=NO \
    build
}

dump_runner_resolved_settings

# Command-line settings override Runner xcconfig. file_picker/DKCamera is
# removed by the patcher; -Onone remains as a belt-and-suspenders override.
# Do not pass nested SPATIAL_CORE_FORCE_LDFLAGS — it never reached ld.
set +e +o pipefail
run_unsigned_xcodebuild 2>&1 | tee "$LOG"
xc_ok=${PIPESTATUS[0]}
if [[ "$xc_ok" -ne 0 ]]; then
  echo "xcodebuild failed; patching derived data and retrying once"
  python3 "$SCRIPT_DIR/patch_ios_file_picker_no_dkcamera.py" "$DERIVED" "$IOS_DIR" || true
  run_unsigned_xcodebuild 2>&1 | tee -a "$LOG"
  xc_ok=${PIPESTATUS[0]}
fi
set -euo pipefail

echo "===== xcodebuild errors (status ${xc_ok}) ====="
if [[ -f "$LOG" ]]; then
  grep -E "error:|fatal error:|Owholemodule|BUILD FAILED|undefined symbol" "$LOG" | tail -n 80 || true
fi
echo "===== end xcodebuild errors ====="

extract_ld_runner || true
if [[ "$xc_ok" -eq 0 ]]; then
  verify_built_runner_ffi
fi

exit "$xc_ok"
