#!/usr/bin/env bash
#
# Everything tool/check.sh does, plus the example app builds and a final review of
# the things a machine cannot decide.
#
# It never publishes. `dn plugin publish` is irreversible and has no --dry-run of
# any kind, so running it stays a deliberate human act.
#
# Usage: tool/prepublish.sh

set -euo pipefail
cd "$(dirname "$0")/.."

step()   { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
manual() { printf '\033[36m*** MANUAL CHECK: %s\033[0m\n' "$1"; }
skip()   { printf '\033[33m--- SKIP: %s\033[0m\n' "$1"; }

step 'Quality gate'
tool/check.sh

step 'Example: dependency resolution and analysis'
(cd example && dn pub get && dn analyze)

step 'Example: Android build'
(cd example && dn build apk --debug)

step 'Example: iOS build'
if [ "$(uname -s)" = "Darwin" ]; then
  (cd example && dn build ios --debug --no-codesign)
else
  skip 'iOS build needs macOS'
fi

step 'Package name availability on dartpub.dev'
NAME=$(grep -m1 '^name:' pubspec.yaml | awk '{print $2}')
CODE=$(curl -s -o /dev/null -w '%{http_code}' "https://dartpub.dev/api/plugins/$NAME" || echo '000')
case "$CODE" in
  404) printf '  %s is free (HTTP 404)\n' "$NAME" ;;
  200) printf '\033[31m  FAIL %s is already taken (HTTP 200). Do NOT publish.\033[0m\n' "$NAME"; exit 1 ;;
  *)   printf '\033[33m  could not check (HTTP %s), verify by hand\033[0m\n' "$CODE" ;;
esac

step 'Publication readiness, the human parts'
cat <<'TXT'
Everything a machine can check has passed. These cannot be automated:

  [ ] The repository is public, owned by you, and `origin` points at it.
      `dn plugin publish` derives --owner from the origin remote.
  [ ] repository and issue_tracker in pubspec.yaml resolve to real pages.
  [ ] Private vulnerability reporting is ENABLED in the repository settings.
      SECURITY.md directs reporters there and names no invented address.
  [ ] The CHANGELOG section for this version is final; it becomes the release
      notes on dartpub.dev.
  [ ] doc/manual-test-matrix.md has been run on real hardware, and the README's
      Limitations section matches what you actually found.
  [ ] You are ready to accept Google's ML Kit Terms of Service as a distributor.
      ML Kit is NOT open source; see THIRD_PARTY_NOTICES.
  [ ] You hold a DartNative subscription if you intend to run the example; the
      free demo licence only runs official DartNative demos.

When all of that is true, publish deliberately:

  dn plugin publish

There is no --dry-run. `dn plugin build`, which tool/check.sh already ran, is the
closest safe rehearsal: it does everything except contact the registry.
TXT
manual 'the checklist above'
