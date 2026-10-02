#!/usr/bin/env bash
#
# The local quality gate. Every command here has been verified to exist in
# dn 1.0.0 stable; nothing is invented.
#
# Deliberately no CI configuration and no GitHub Actions: this script is the gate,
# and it runs on a developer's machine where the devices are.
#
# Usage: tool/check.sh

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

# `dn format` does not exist. Formatting goes through the SDK's own Dart, which is
# beside the dn executable.
DN_BIN="$(dirname "$(command -v dn)")"
DART="$DN_BIN/dart"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
skip() { printf '\033[33m--- SKIP: %s\033[0m\n' "$1"; }
manual() { printf '\033[36m*** MANUAL CHECK: %s\033[0m\n' "$1"; }

step 'Dart SDK and toolchain'
dn --version | head -1
"$DART" --version

step 'Dependency resolution'
# dart pub get would fail by design: DartNative packages resolve from the
# installed SDK, not from pub.dev.
dn pub get

step 'Format verification'
"$DART" format --output=none --set-exit-if-changed lib test

step 'Static analysis'
# dn analyze treats infos AND warnings as fatal by default. Keep it that way.
dn analyze

step 'Dart tests'
dn test

step 'Native build: Android AAR and iOS xcframework'
# The real compile gate for both native sides. It also produces the generated
# Android harness that the Kotlin tests need, which is why it runs first.
dn plugin build

step 'Kotlin unit tests'
HARNESS="$ROOT/dist/_build_android"
if [ -x "$HARNESS/gradlew" ]; then
  # Run through the harness dn plugin build generated: it is the only Gradle
  # project with :dartnative_android wired up, which this module compiles against.
  (cd "$HARNESS" && ./gradlew :mobile_scanner:testReleaseUnitTest --console=plain -q)
  REPORT="$ROOT/android/build/test-results/testReleaseUnitTest"
  if [ -d "$REPORT" ]; then
    python3 - "$REPORT" <<'PY'
import glob, sys, xml.etree.ElementTree as ET
total = fails = 0
for path in glob.glob(sys.argv[1] + '/TEST-*.xml'):
    root = ET.parse(path).getroot()
    total += int(root.get('tests') or 0)
    fails += int(root.get('failures') or 0) + int(root.get('errors') or 0)
print(f'Kotlin tests: {total} run, {fails} failed')
sys.exit(1 if fails or not total else 0)
PY
  else
    skip 'no Kotlin test report produced'
  fi
else
  skip 'Kotlin tests: dist/_build_android missing, run dn plugin build first'
fi

step 'Package metadata'
python3 - <<'PY'
import re, sys, pathlib

pubspec = pathlib.Path('pubspec.yaml').read_text()
problems = []

def need(pattern, label):
    if not re.search(pattern, pubspec, re.M):
        problems.append(label)

need(r'^name: mobile_scanner$', 'name')
need(r'^version: \d+\.\d+\.\d+', 'version')
need(r'^repository: https://', 'repository')
need(r'^issue_tracker: https://', 'issue_tracker')
need(r"^publish_to: 'none'$", "publish_to: 'none' (the registry is dartpub.dev)")
need(r'ffiPlugin: true', 'ios ffiPlugin')
need(r'pluginClass: DartNativeMobileScannerPlugin', 'android pluginClass')

# android: ffiPlugin would stop JNI_OnLoad ever firing.
android = pubspec.split('android:', 1)[-1].split('registrant:', 1)[0]
if 'ffiPlugin' in android:
    problems.append('android must use pluginClass, never ffiPlugin')

version = re.search(r'^version: (\S+)', pubspec, re.M).group(1)
changelog = pathlib.Path('CHANGELOG.md').read_text()
if f'## {version}' not in changelog:
    problems.append(f'CHANGELOG.md has no "## {version}" section')

for required in ('README.md', 'LICENSE', 'CHANGELOG.md', 'CONTRIBUTING.md',
                 'SECURITY.md', 'THIRD_PARTY_NOTICES'):
    if not pathlib.Path(required).exists():
        problems.append(f'missing {required}')

if not pathlib.Path('example/pubspec.yaml').exists():
    problems.append('missing example/ (dartpub requires one)')

if problems:
    for p in problems:
        print(f'  FAIL {p}')
    sys.exit(1)
print(f'  metadata OK, version {version}')
PY

step 'Release hygiene audit'
tool/audit.sh

step 'Done'
printf '\033[32mAll automated checks passed.\033[0m\n'
manual 'example builds: run tool/prepublish.sh'
manual 'device behaviour: doc/manual-test-matrix.md, on real hardware'
manual 'hot restart: start a scan, press capital R, confirm no abort'
