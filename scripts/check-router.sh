#!/usr/bin/env bash
# Check an OpenAI-compatible router endpoint and probe its models.
# Reads the API key from MICRO_AI_API_KEY|MICRO_AI_API_KEYS or from
# ~/.config/micro-ubuntu/api-keys (one key per line). Never prints the key.
#
#   ./scripts/check-router.sh [endpoint] [model1 model2 ...]
#
# Default endpoint: https://router.bynara.id/v1/chat/completions
# Default probes:  the free-tier models of NaraRouter (usable without a paid plan).
set -Eeuo pipefail
shopt -s nocasematch

ENDPOINT=${1:-https://router.bynara.id/v1/chat/completions}
BASE=${ENDPOINT%/chat/completions}
BASE=${BASE%/}

key=""
if [[ -n "${MICRO_AI_API_KEYS:-}" ]]; then
  key=$(printf '%s\n' "$MICRO_AI_API_KEYS" | head -n 1 | tr -d '[:space:]')
elif [[ -n "${MICRO_AI_API_KEY:-}" ]]; then
  key=$(printf '%s' "$MICRO_AI_API_KEY" | tr -d '[:space:]')
elif [[ -r "$HOME/.config/micro-ubuntu/api-keys" ]]; then
  key=$(grep -m1 '^[^#[:space:]]' "$HOME/.config/micro-ubuntu/api-keys" | tr -d '[:space:]')
fi
if [[ -z "$key" ]]; then
  echo 'No API key found. Set MICRO_AI_API_KEYS or add it to ~/.config/micro-ubuntu/api-keys.' >&2
  exit 2
fi

FREE_MODELS=(
  agnes-2.0-flash
  agnes-2.5-flash
  glm-5.3-flash-free
  laguna-s-2.1
  minimax-m3-free
  mistral-large
  mistral-medium-3-5
  nemotron-3-ultra
  qwen3.8-27b
  stepfun-3.7-flash
  tencent-hy3-free
  deepseek-v4-flash
)

if (($# > 1)); then
  models=("${@:2}")
else
  models=("${FREE_MODELS[@]}")
fi

echo "== Router: $BASE =="
echo "== Listing models at ${BASE}/models =="
list=$(curl -sS -m 30 -H "Authorization: Bearer $key" "${BASE}/models" || true)
if [[ -z "$list" ]]; then
  echo 'Could not fetch /models (network or auth problem).' >&2
  exit 1
fi
if [[ "$list" == *unauthorized* || "$list" == *"A valid API key"* ]]; then
  echo 'The server rejected the API key (401).' >&2
  echo "$list" | head -c 300 >&2
  exit 1
fi
ids=$(printf '%s' "$list" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
rows=d.get("data") or d.get("models") or (d if isinstance(d,list) else [])
for r in rows:
    if isinstance(r,str): print(r)
    elif isinstance(r,dict) and r.get("id"): print(r["id"])
' 2>/dev/null || true)
echo "Models exposed by the endpoint: $(printf '%s' "$ids" | grep -c . ) (list follows)" >&2
echo "$ids" | head -n 80

echo
echo "== Probing ${#models[@]} models =="
declare -A seen
for model in "${models[@]}"; do
  [[ -n "$model" ]] || continue
  [[ -n "${seen[$model]:-}" ]] && continue
  seen[$model]=1
  http=$(curl -sS -m 60 -o /tmp/router_probe.$$.json -w '%{http_code}' \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -X POST "$ENDPOINT" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"max_tokens\":16}" || echo 000)
  body=$(cat /tmp/router_probe.$$.json 2>/dev/null || true)
  rm -f /tmp/router_probe.$$.json
  verdict="?"
  if [[ "$http" == 200 ]]; then
    reply=$(printf '%s' "$body" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print((d.get("choices") or [{}])[0].get("message",{}).get("content",""))
except Exception:
    pass
' 2>/dev/null | tr -d '\n')
    if [[ -n "$reply" ]]; then verdict="WORKING ($reply)"; else verdict="200 but empty reply"; fi
  elif [[ "$http" == 401 || "$http" == 403 ]]; then
    verdict="NOT WORKING - auth rejected"
  elif [[ "$http" == 429 ]]; then
    verdict="RATE LIMITED - quota/billing, model may need paid plan"
  elif [[ "$http" == 400 ]]; then
    verdict="400 - model unknown or payload rejected"
  elif [[ "$http" == 402 ]]; then
    verdict="PAYMENT REQUIRED - plan/PAYG needed"
  else
    verdict="HTTP $http - $(printf '%s' "$body" | head -c 160 | tr -d '\n')"
  fi
  printf '%-32s HTTP %s  %s\n' "$model" "$http" "$verdict"
done
