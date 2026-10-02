#!/usr/bin/env bash
#
# Release hygiene: forbidden patterns, secrets, and machine-local paths.
# Run by tool/check.sh; safe to run on its own.

set -euo pipefail
cd "$(dirname "$0")/.."

# Only files that would actually ship. Build output and the pub cache are not ours.
sources() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files
    return
  fi
  # Not a git repository yet, so approximate what .gitignore would exclude.
  # `git ls-files` above is the exact answer; this branch is a best effort for a
  # tree that has not been initialised yet.
  find . \
    -name .git -prune -o \
    -name .idea -prune -o \
    -name .symlinks -prune -o \
    -name 'local.properties' -prune -o \
    -name 'Generated.xcconfig' -prune -o \
    -name 'dn_export_environment.sh' -prune -o \
    -name '.dn-plugins-dependencies' -prune -o \
    -name 'dartnative_plugin_registrant.dart' -prune -o \
    -name .dart_tool -prune -o \
    -name .cxx -prune -o \
    -name .gradle -prune -o \
    -name build -prune -o \
    -name dist -prune -o \
    -name Pods -prune -o \
    -name .scratch -prune -o \
    -name '*.xcworkspace' -prune -o \
    -name '*.xcodeproj' -prune -o \
    -type f -print
}

FAILED=0
report() { printf '\033[31m  FAIL %s\033[0m\n' "$1"; FAILED=1; }
ok()     { printf '  ok   %s\n' "$1"; }

# A pattern that must appear nowhere in shipping sources.
forbid() {
  local label="$1" pattern="$2"
  local hits
  hits=$(sources | xargs grep -l -I -E "$pattern" 2>/dev/null \
    | grep -vE '^(\./)?(tool/audit\.sh|doc/|README\.md|THIRD_PARTY_NOTICES|CONTRIBUTING\.md)' || true)
  if [ -n "$hits" ]; then
    report "$label"
    echo "$hits" | sed 's/^/         /'
  else
    ok "$label"
  fi
}

printf '\n-- Flutter architecture --\n'
forbid 'no MethodChannel'            'MethodChannel'
forbid 'no EventChannel'             'EventChannel'
forbid 'no package:flutter import'   "import 'package:flutter/|import \"package:flutter/"
forbid 'no FlutterActivity'          'FlutterActivity'
forbid 'no FlutterEngine'            'FlutterEngine'

printf '\n-- Permissions --\n'
forbid 'no MANAGE_EXTERNAL_STORAGE'  'MANAGE_EXTERNAL_STORAGE'
forbid 'no READ_EXTERNAL_STORAGE'    'READ_EXTERNAL_STORAGE'
forbid 'no WRITE_EXTERNAL_STORAGE'   'WRITE_EXTERNAL_STORAGE'

printf '\n-- Unfinished work --\n'
forbid 'no TODO'                     '\bTODO\b'
forbid 'no FIXME'                    '\bFIXME\b'
forbid 'no XXX marker'               '\bXXX\b'
forbid 'no HACK marker'              '\bHACK\b'

printf '\n-- Attribution --\n'
forbid 'no AI tool attribution'      '[Cc]laude|[Aa]nthropic|ChatGPT|OpenAI|Copilot|AI-generated|AI-assisted|Co-authored-by'

printf '\n-- CI --\n'
if [ -d .github/workflows ]; then
  report 'no GitHub Actions workflows (.github/workflows exists)'
else
  ok 'no GitHub Actions workflows'
fi

printf '\n-- Secrets --\n'
forbid 'no private keys'             'BEGIN (RSA |EC |OPENSSH |PGP )?PRIVATE KEY'
forbid 'no AWS keys'                 'AKIA[0-9A-Z]{16}'
forbid 'no Google API keys'          'AIza[0-9A-Za-z_-]{35}'
forbid 'no bearer tokens'            'ghp_[0-9A-Za-z]{36}|dnp_[0-9A-Za-z]{20,}'
forbid 'no google-services.json'     'google-services\.json'

printf '\n-- Machine-local paths --\n'
hits=$(sources | xargs grep -l -I -E '/Users/[a-z]|/home/[a-z]|C:\\\\Users' 2>/dev/null \
  | grep -vE '^(\./)?(tool/audit\.sh|doc/|CONTRIBUTING\.md)' || true)
if [ -n "$hits" ]; then
  printf '\033[31m  FAIL no absolute local paths\033[0m\n'
  echo "$hits" | sed 's/^/         /'
  FAILED=1
else
  ok 'no absolute local paths'
fi

printf '\n-- Barcode values must not be logged --\n'
# A scanned value can be a credential. It must never reach a release log.
# Doc comments showing `print(barcode.rawValue)` as example code are
# documentation, not a log call, so comment lines are excluded.
hits=$(grep -rn -E 'Log\.[diwev]\(.*(rawValue|displayValue)|print\(.*rawValue' \
  android/src ios/Classes lib 2>/dev/null \
  | grep -vE ':[[:space:]]*(///|//|\*)' || true)
if [ -n "$hits" ]; then
  printf '\033[31m  FAIL barcode values appear in a log statement\033[0m\n'
  echo "$hits" | sed 's/^/         /'
  FAILED=1
else
  ok 'no barcode values in log statements'
fi

printf '\n'
if [ "$FAILED" -ne 0 ]; then
  printf '\033[31mAudit failed.\033[0m\n'
  exit 1
fi
printf '\033[32mAudit clean.\033[0m\n'
