#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$PROJECT_ROOT"

printf '%s\n' 'Running bash syntax checks...'
while IFS= read -r -d '' file; do
  bash -n "$file"
done < <(find scripts tests -type f -name '*.sh' -print0)

printf '%s\n' 'Running POSIX shell syntax checks...'
while IFS= read -r -d '' file; do
  sh -n "$file"
done < <(find src tests -type f -print0 | while IFS= read -r -d '' candidate; do
  if head -n 1 "$candidate" | grep -q '^#!/bin/sh'; then printf '%s\0' "$candidate"; fi
done)

printf '%s\n' 'Running Python compilation checks...'
python_files=()
while IFS= read -r -d '' file; do
  python_files+=("$file")
done < <(find scripts src tests -type f -print0 | while IFS= read -r -d '' candidate; do
  if head -n 1 "$candidate" | grep -Eq '^#!/usr/bin/env python3|^#!/usr/bin/python3'; then
    printf '%s\0' "$candidate"
  fi
done)
if ((${#python_files[@]})); then
  python3 -m py_compile "${python_files[@]}"
fi
find . -type d -name __pycache__ -prune -exec rm -rf {} +

./tests/test-installer-functions.sh

printf '%s\n' 'Running MicroAI Gemini provider unit tests...'
python3 tests/test_micro_ai.py
# The unit test executes suffix-less sources directly; drop any bytecode it made.
find . -type d -name __pycache__ -prune -exec rm -rf {} +

printf '%s\n' 'Checking release safety invariants...'
menu_count=$(grep -c "^[[:space:]]*menuentry '" scripts/build-iso.sh)
[[ $menu_count -eq 2 ]] || { echo "Expected two GRUB menuentry declarations, found $menu_count" >&2; exit 1; }
grep -Fq "menuentry 'MicroUbuntu - Temporary session'" scripts/build-iso.sh
grep -Fq "menuentry 'MicroUbuntu - Normal installation (Ubuntu terminal system)'" scripts/build-iso.sh
grep -Fq "console=ttyS0,115200n8 console=tty0" scripts/build-iso.sh
grep -Fq "Type exactly INSTALL" src/initramfs/usr/bin/normal-install
grep -Fq "verify_remote_payload \"\$IMAGE_URL\" \"\$IMAGE_SHA256\"" src/initramfs/usr/bin/normal-install
grep -Fq 'AI_RUN_AS_ROOT=0' src/normal/etc/micro-ubuntu/ai.conf
if grep -Rq '^AI_RUN_AS_ROOT=1' src config scripts; then
  echo 'Unsafe AI_RUN_AS_ROOT=1 default found.' >&2
  exit 1
fi

# Credential material must never be committed: no key/cookie stores in the tree.
if git ls-files | grep -Eqi 'cookies?(\.json|\.txt)?$|cookie-export|api-keys|apikeys'; then
  echo 'A committed file looks like a credential store.' >&2
  exit 1
fi
# Reject credential-looking assignment lines (real exports start with these).
if grep -RqE '^(SAPISID|__Secure-1PSID|__Secure-3PSID|SID|HSID|SSID|APISID|NID|SIDCC)=' \
    src config scripts tests; then
  echo 'Credential-like assignment found in the repository.' >&2
  exit 1
fi
# No real-looking API key (sk-...) may be committed in source or docs.
if grep -RnE 'sk-[A-Za-z0-9_-]{16,}' src config scripts README.md GITHUB_BUILD_PROMPT.txt \
    --exclude='test_micro_ai.py'; then
  echo 'A committed string looks like an API key.' >&2
  exit 1
fi

# The default provider must be safe auto routing, never a hard-coded key.
grep -Fq 'AI_PROVIDER=auto' src/normal/etc/micro-ubuntu/ai.conf || {
  echo 'Expected AI_PROVIDER=auto default.' >&2
  exit 1
}
grep -Fq 'AI_ROUTES=' src/normal/etc/micro-ubuntu/ai.conf || {
  echo 'AI_ROUTES setting missing from ai.conf.' >&2
  exit 1
}
grep -Fq 'AI_BRAIN=' src/normal/etc/micro-ubuntu/ai.conf || {
  echo 'AI_BRAIN setting missing from ai.conf.' >&2
  exit 1
}
grep -Fq 'AI_API_MODEL=auto' src/normal/etc/micro-ubuntu/ai.conf || {
  echo 'Expected AI_API_MODEL=auto default for model auto-selection.' >&2
  exit 1
}
grep -Fq 'AI_MODEL_PREFERENCE=' src/normal/etc/micro-ubuntu/ai.conf || {
  echo 'AI_MODEL_PREFERENCE setting missing from ai.conf.' >&2
  exit 1
}
grep -Fq 'AI_GEMINI_MODEL=gemini-auto' src/normal/etc/micro-ubuntu/ai.conf || {
  echo 'Expected AI_GEMINI_MODEL=gemini-auto default.' >&2
  exit 1
}
grep -Fq 'AI_API_KEYS_FILE=' src/normal/etc/micro-ubuntu/ai.conf || {
  echo 'AI_API_KEYS_FILE setting missing from ai.conf.' >&2
  exit 1
}
grep -Fq 'AI_GEMINI_COOKIE_DIR=' src/normal/etc/micro-ubuntu/ai.conf || {
  echo 'AI_GEMINI_COOKIE_DIR setting missing from ai.conf.' >&2
  exit 1
}

for choice in \
  '1. Terminal-based system' \
  '2. Build graphical interface' \
  '3. Decide later'; do
  grep -Fq "$choice" src/normal/usr/local/bin/micro-first-login
 done
# Comments may explain why mdev -s is unsafe; reject only executable invocations.
if grep -RE '^[[:space:]]*mdev[[:space:]]+-s([[:space:]]|$)' src/initramfs; then
  echo 'Unbounded mdev -s invocation found.' >&2
  exit 1
fi

grep -Fq 'workflow_dispatch:' .github/workflows/build-micro-ubuntu.yml 2>/dev/null || {
  echo 'GitHub Actions workflow is missing.' >&2
  exit 1
}

printf '%s\n' 'All static and non-destructive installer tests passed.'
