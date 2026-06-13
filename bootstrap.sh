#!/usr/bin/env bash
# fable-up: one-command bootstrap for opencode + Anthropic with SOC 2-aligned audit logging.
# Usage: ./bootstrap.sh [--check] [--force-download] [--no-warmup] [--prime-cache] [--verbose]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FABLE_HOME="${FABLE_HOME:-$HOME/.fable}"
STATE_FILE="$FABLE_HOME/state.json"
INSTALL_DIR="$HOME/.local/bin"
VENV_DIR="$FABLE_HOME/venv"
ANTHROPIC_API="https://api.anthropic.com"
PYTHON="python3"  # overridden after venv setup

CHECK_ONLY=0
FORCE_DOWNLOAD=0
NO_WARMUP=0
PRIME_CACHE=0
VERBOSE=0

for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --force-download) FORCE_DOWNLOAD=1 ;;
    --no-warmup) NO_WARMUP=1 ;;
    --prime-cache) PRIME_CACHE=1 ;;
    --verbose) VERBOSE=1 ;;
    -h|--help)
      sed -n '2,3p' "$0"; exit 0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# ---------- helpers ----------
PHASES=()
phase_result() { PHASES+=("$1 $2"); }
log()  { printf '%s\n' "$*"; }
vlog() { [ "$VERBOSE" -eq 1 ] && printf '  [v] %s\n' "$*" || true; }
die()  {
  printf '\n\xe2\x9c\x97 FAILED at phase: %s\n  %s\n' "$1" "$2" >&2
  phase_result "✗" "$1"
  print_summary
  exit 1
}
print_summary() {
  printf '\n==== bootstrap summary ====\n'
  for p in "${PHASES[@]}"; do printf '  %s\n' "$p"; done
}

http_get() { # url -> stdout, fails on non-2xx
  curl -fsSL --proto '=https' --tlsv1.2 "$1"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "prereqs" "required command not found: $1"
}

# ---------- phase 0: cleanup ----------
phase0_cleanup() {
  log "== Phase 1/10: cleanup stale processes/ports"
  FABLE_PROXY_PORT="${FABLE_PROXY_PORT:-8377}"
  local pidfile="$FABLE_HOME/proxy.pid"
  local killed=0

  # kill by pidfile
  if [ -f "$pidfile" ]; then
    local oldpid
    oldpid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
      if [ "$CHECK_ONLY" -eq 1 ]; then
        log "  [check] would kill proxy pid $oldpid"
      else
        log "  killing previous proxy (pid $oldpid)"
        kill "$oldpid" 2>/dev/null || true
        killed=1
      fi
    fi
    [ "$CHECK_ONLY" -eq 1 ] || rm -f "$pidfile"
  fi

  # kill anything still holding the port
  if command -v lsof >/dev/null 2>&1; then
    local pids
    pids="$(lsof -ti tcp:"$FABLE_PROXY_PORT" -sTCP:LISTEN 2>/dev/null || true)"
    if [ -n "$pids" ]; then
      if [ "$CHECK_ONLY" -eq 1 ]; then
        log "  [check] would kill process(es) on port $FABLE_PROXY_PORT: $pids"
      else
        log "  killing process(es) on port $FABLE_PROXY_PORT: $pids"
        echo "$pids" | xargs kill 2>/dev/null || true
        killed=1
      fi
    fi
  elif command -v ss >/dev/null 2>&1; then
    local pids
    pids="$(ss -tlnp "sport = :$FABLE_PROXY_PORT" 2>/dev/null | grep -oP 'pid=\K[0-9]+' || true)"
    if [ -n "$pids" ]; then
      if [ "$CHECK_ONLY" -eq 1 ]; then
        log "  [check] would kill process(es) on port $FABLE_PROXY_PORT: $pids"
      else
        log "  killing process(es) on port $FABLE_PROXY_PORT: $pids"
        echo "$pids" | xargs kill 2>/dev/null || true
        killed=1
      fi
    fi
  fi

  if [ "$killed" -eq 1 ]; then
    sleep 0.5  # let port free up
    log "  cleanup complete"
  else
    log "  nothing to clean"
  fi
  phase_result "✓" "cleanup"
}

# ---------- phase 1: platform detection ----------
phase1_platform() {
  log "== Phase 2/10: platform detection"
  need_cmd uname; need_cmd curl

  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  DETECTED_OS="$os"
  FORM_FACTOR="desktop"
  IS_TERMUX=0
  if [ -n "${TERMUX_VERSION:-}" ] || { [ -n "${PREFIX:-}" ] && [[ "${PREFIX:-}" == *com.termux* ]]; }; then
    IS_TERMUX=1; FORM_FACTOR="mobile"
  elif [ -d /sys/class/power_supply ] && ls /sys/class/power_supply 2>/dev/null | grep -qi '^bat'; then
    FORM_FACTOR="laptop"
  fi

  case "$os/$arch" in
    Linux/x86_64)            OC_TARGET="linux-x64" ;;
    Linux/aarch64|Linux/arm64) OC_TARGET="linux-arm64" ;;
    Darwin/arm64)            OC_TARGET="darwin-arm64" ;;
    Darwin/x86_64)           OC_TARGET="darwin-x64" ;;
    *) die "platform" "unsupported platform: $os/$arch (Windows: use WSL)" ;;
  esac

  log "  os=$os arch=$arch target=$OC_TARGET form_factor=$FORM_FACTOR termux=$IS_TERMUX"
  phase_result "✓" "platform detection ($OC_TARGET, $FORM_FACTOR)"
}

# ---------- phase 1b: python + venv ----------
phase1b_python() {
  log "== Phase 3/10: python + venv"

  # --- auto-install python3 if missing ---
  if ! command -v python3 >/dev/null 2>&1; then
    log "  python3 not found — attempting auto-install"
    if [ "$CHECK_ONLY" -eq 1 ]; then
      log "  [check] would install python3 via package manager"
      phase_result "✗" "python3 missing (check mode)"
      return
    fi
    local installed=0
    if [ "$IS_TERMUX" -eq 1 ]; then
      log "  detected Termux — pkg install python"
      pkg install -y python && installed=1
    elif [ "$DETECTED_OS" = "Linux" ]; then
      if command -v apt-get >/dev/null 2>&1; then
        log "  detected apt — installing python3 python3-venv"
        sudo apt-get update -qq && sudo apt-get install -y -qq python3 python3-venv && installed=1
      elif command -v dnf >/dev/null 2>&1; then
        log "  detected dnf — installing python3"
        sudo dnf install -y -q python3 && installed=1
      elif command -v pacman >/dev/null 2>&1; then
        log "  detected pacman — installing python"
        sudo pacman -Sy --noconfirm python && installed=1
      elif command -v apk >/dev/null 2>&1; then
        log "  detected apk — installing python3"
        sudo apk add --quiet python3 && installed=1
      elif command -v zypper >/dev/null 2>&1; then
        log "  detected zypper — installing python3"
        sudo zypper install -y python3 && installed=1
      fi
    elif [ "$DETECTED_OS" = "Darwin" ]; then
      if command -v brew >/dev/null 2>&1; then
        log "  detected brew — installing python@3"
        brew install python@3 && installed=1
      else
        die "python" "python3 not found and Homebrew not available. Install: https://brew.sh then re-run."
      fi
    fi
    if [ "$installed" -eq 0 ]; then
      die "python" "could not auto-install python3. Install it manually and re-run."
    fi
    command -v python3 >/dev/null 2>&1 || die "python" "python3 still not on PATH after install attempt"
    log "  python3 installed: $(python3 --version)"
  else
    vlog "python3 already present: $(python3 --version)"
  fi

  # --- ensure python3-venv module is available (Debian/Ubuntu split it out) ---
  if ! python3 -m venv --help >/dev/null 2>&1; then
    log "  python3-venv module missing — attempting install"
    if [ "$CHECK_ONLY" -eq 1 ]; then
      log "  [check] would install python3-venv"
    elif command -v apt-get >/dev/null 2>&1; then
      local pyver
      pyver="$(python3 -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
      sudo apt-get install -y -qq "python3-venv" "python${pyver:+$pyver}-venv" 2>/dev/null \
        || sudo apt-get install -y -qq python3-venv \
        || die "python" "failed to install python3-venv. Run: sudo apt install python3-venv"
    fi
    python3 -m venv --help >/dev/null 2>&1 || die "python" "python3-venv still unavailable after install attempt"
  fi

  # --- create or reuse venv ---
  if [ -x "$VENV_DIR/bin/python" ] && "$VENV_DIR/bin/python" -c 'import sys; assert sys.version_info >= (3,8)' 2>/dev/null; then
    vlog "venv exists at $VENV_DIR"
  else
    if [ "$CHECK_ONLY" -eq 1 ]; then
      log "  [check] would create venv at $VENV_DIR"
      phase_result "−" "python + venv (check mode)"
      PYTHON="python3"
      return
    fi
    log "  creating venv at $VENV_DIR"
    mkdir -p "$FABLE_HOME"
    python3 -m venv "$VENV_DIR"
  fi
  PYTHON="$VENV_DIR/bin/python"

  # --- install deps if requirements.txt exists and has content ---
  local reqfile="$REPO_ROOT/requirements.txt"
  if [ -s "$reqfile" ]; then
    local marker="$VENV_DIR/.deps-hash"
    local current_hash
    current_hash="$(sha256sum "$reqfile" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$reqfile" | awk '{print $1}')"
    if [ -f "$marker" ] && [ "$(cat "$marker")" = "$current_hash" ]; then
      vlog "requirements.txt unchanged — skipping pip install"
    else
      if [ "$CHECK_ONLY" -eq 1 ]; then
        log "  [check] would pip install -r requirements.txt"
      else
        log "  installing dependencies from requirements.txt"
        "$PYTHON" -m pip install --quiet --upgrade pip 2>/dev/null || true
        "$PYTHON" -m pip install --quiet -r "$reqfile" \
          || die "python" "pip install -r requirements.txt failed"
        echo "$current_hash" > "$marker"
      fi
    fi
  fi

  log "  python=$("$PYTHON" --version), venv=$VENV_DIR"
  phase_result "✓" "python + venv"
}

# ---------- phase 2: fable build from source ----------
FABLE_FORK_URL="${FABLE_FORK_URL:-https://github.com/salus-ryan/opencode.git}"
FABLE_SRC_DIR="$REPO_ROOT/opencode-src"

phase2_opencode() {
  log "== Phase 4/10: fable build from source"
  OPENCODE_BIN=""

  # check for existing fable binary first
  if [ "$FORCE_DOWNLOAD" -eq 0 ]; then
    if command -v fable >/dev/null 2>&1 && fable --version >/dev/null 2>&1; then
      OPENCODE_BIN="$(command -v fable)"
    elif [ -x "$INSTALL_DIR/fable" ] && "$INSTALL_DIR/fable" --version >/dev/null 2>&1; then
      OPENCODE_BIN="$INSTALL_DIR/fable"
    fi
  fi

  if [ -n "$OPENCODE_BIN" ] && [ "$FORCE_DOWNLOAD" -eq 0 ]; then
    OC_VERSION="$("$OPENCODE_BIN" --version 2>/dev/null | head -1)"
    log "  existing fable found: $OPENCODE_BIN ($OC_VERSION) — skipping build"
    phase_result "✓" "fable present ($OC_VERSION)"
    return
  fi

  if [ "$CHECK_ONLY" -eq 1 ]; then
    log "  [check] fable not installed; would build from source"
    phase_result "✗" "fable missing (check mode, no build)"
    return
  fi

  # require Go
  if ! command -v go >/dev/null 2>&1; then
    die "fable build" "Go is not installed. Install Go 1.22+ from https://go.dev/dl/"
  fi
  local go_ver
  go_ver="$(go version | awk '{print $3}')"
  log "  go: $go_ver"

  # clone or update fork
  if [ -d "$FABLE_SRC_DIR/.git" ]; then
    log "  updating fork..."
    git -C "$FABLE_SRC_DIR" pull --ff-only origin main 2>/dev/null || true
  else
    log "  cloning fork from $FABLE_FORK_URL..."
    git clone "$FABLE_FORK_URL" "$FABLE_SRC_DIR" \
      || die "fable build" "git clone failed"
  fi

  # build
  log "  building fable..."
  mkdir -p "$INSTALL_DIR"
  (cd "$FABLE_SRC_DIR" && go build -o "$INSTALL_DIR/fable" .) \
    || die "fable build" "go build failed"

  OPENCODE_BIN="$INSTALL_DIR/fable"
  OC_VERSION="$("$OPENCODE_BIN" --version 2>/dev/null | head -1)"
  [ -n "$OC_VERSION" ] || die "fable build" "built binary failed --version"
  case ":$PATH:" in *":$INSTALL_DIR:"*) ;; *) log "  NOTE: add $INSTALL_DIR to PATH";; esac
  log "  built fable $OC_VERSION -> $OPENCODE_BIN"
  phase_result "✓" "fable built ($OC_VERSION)"
}

# ---------- phase 3: credential verification ----------
phase3_credentials() {
  log "== Phase 5/10: ANTHROPIC_API_KEY verification"
  local env_file="$REPO_ROOT/.env"

  # If .env is missing, seed it from .env.example
  if [ ! -f "$env_file" ]; then
    if [ -f "$REPO_ROOT/.env.example" ]; then
      cp "$REPO_ROOT/.env.example" "$env_file"
      chmod 600 "$env_file"
      log "  created .env from .env.example"
    else
      touch "$env_file"
      chmod 600 "$env_file"
    fi
  fi

  # tighten perms
  local mode
  mode="$(stat -c '%a' "$env_file" 2>/dev/null || stat -f '%Lp' "$env_file")"
  if [ "$mode" != "600" ]; then
    if [ "$CHECK_ONLY" -eq 1 ]; then
      log "  [check] .env perms are $mode; would tighten to 0600"
    else
      chmod 600 "$env_file"
      log "  .env perms tightened to 0600 (was $mode)"
    fi
  fi

  # gitignore safety
  if git -C "$REPO_ROOT" rev-parse >/dev/null 2>&1; then
    if git -C "$REPO_ROOT" ls-files --error-unmatch .env >/dev/null 2>&1; then
      log "  WARNING: .env is TRACKED by git. Remove it: git rm --cached .env"
    fi
    grep -qxF '.env' "$REPO_ROOT/.gitignore" 2>/dev/null || {
      [ "$CHECK_ONLY" -eq 1 ] || printf '.env\n' >> "$REPO_ROOT/.gitignore"
      log "  added .env to .gitignore"
    }
  fi

  # load .env (only lines KEY=VALUE, no export needed)
  set -a; # shellcheck disable=SC1090
  . "$env_file"; set +a

  # If key is still missing, wait for it via the proxy's /setup page
  if [ -z "${ANTHROPIC_API_KEY:-}" ] || [ "${ANTHROPIC_API_KEY:-}" = "sk-ant-your-key-here" ]; then
    if [ "$CHECK_ONLY" -eq 1 ]; then
      log "  [check] ANTHROPIC_API_KEY not set; would wait for browser key entry via proxy /setup"
      phase_result "−" "credentials (check mode, key missing)"; return
    fi
    FABLE_PROXY_PORT="${FABLE_PROXY_PORT:-8377}"
    log "  ANTHROPIC_API_KEY not set — waiting for key via http://localhost:$FABLE_PROXY_PORT/setup"
    log "  Open that URL in your browser and paste your Anthropic API key."
    local attempts=0
    local max_attempts=600  # 5 minutes at 0.5s intervals
    while [ "$attempts" -lt "$max_attempts" ]; do
      if curl -fsS "http://127.0.0.1:$FABLE_PROXY_PORT/healthz" 2>/dev/null \
           | "$PYTHON" -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("key_configured") else 1)' 2>/dev/null; then
        log "  key received via browser"
        break
      fi
      attempts=$((attempts + 1))
      sleep 0.5
    done
    [ "$attempts" -lt "$max_attempts" ] || die "credentials" "timed out waiting for API key via /setup. Set ANTHROPIC_API_KEY in .env manually."
    # reload .env after proxy wrote it
    set -a; . "$env_file"; set +a
  fi

  [ -n "${ANTHROPIC_API_KEY:-}" ] || die "credentials" "ANTHROPIC_API_KEY missing or empty in .env"
  case "$ANTHROPIC_API_KEY" in
    sk-ant-*) ;;
    *) die "credentials" "ANTHROPIC_API_KEY malformed (expected sk-ant-* prefix)" ;;
  esac

  # live check (key never echoed)
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    "$ANTHROPIC_API/v1/models")"
  [ "$status" = "200" ] || die "credentials" "live key check failed: HTTP $status from GET /v1/models"
  log "  key present, well-formed, live-verified (HTTP 200)"
  phase_result "✓" "credentials verified"
}

# ---------- phase 4: warmup ----------
phase4_warmup() {
  log "== Phase 6/10: Anthropic warmup"
  if [ "$NO_WARMUP" -eq 1 ]; then
    log "  skipped (--no-warmup)"; phase_result "−" "warmup skipped"; return
  fi
  local warmup_model="${FABLE_MODEL:-claude-sonnet-4-5}"
  local body sys_block="" resp meta status ttfb total
  if [ "$PRIME_CACHE" -eq 1 ] && [ -f "$REPO_ROOT/prompts/system.md" ]; then
    sys_block="$("$PYTHON" - "$REPO_ROOT/prompts/system.md" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
print(json.dumps([{"type": "text", "text": text, "cache_control": {"type": "ephemeral"}}]))
PY
)"
  fi
  body="$("$PYTHON" - "$warmup_model" "$sys_block" <<'PY'
import json, sys
model, sys_block = sys.argv[1], sys.argv[2]
req = {"model": model, "max_tokens": 16,
       "messages": [{"role": "user", "content": "warmup: reply with the single word ok"}]}
if sys_block:
    req["system"] = json.loads(sys_block)
print(json.dumps(req))
PY
)"
  resp="$(mktemp)"; meta="$(mktemp)"
  curl -s -o "$resp" -w '%{http_code} %{time_starttransfer} %{time_total}' \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$body" "$ANTHROPIC_API/v1/messages" > "$meta" || die "warmup" "network failure calling /v1/messages"
  read -r status ttfb total < "$meta" || true
  if [ "$status" != "200" ]; then
    local etype
    etype="$("$PYTHON" -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("error",{}).get("type","unknown"))' "$resp" 2>/dev/null || echo unknown)"
    rm -f "$resp" "$meta"
    die "warmup" "HTTP $status ($etype) from /v1/messages for model $warmup_model"
  fi
  "$PYTHON" - "$resp" "$ttfb" "$total" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); u = d.get("usage", {})
print(f"  model={d.get('model')} ttfb={float(sys.argv[2])*1000:.0f}ms total={float(sys.argv[3])*1000:.0f}ms "
      f"in={u.get('input_tokens')} out={u.get('output_tokens')} "
      f"cache_read={u.get('cache_read_input_tokens', 0)} cache_write={u.get('cache_creation_input_tokens', 0)}")
PY
  rm -f "$resp" "$meta"
  phase_result "✓" "warmup ($warmup_model)"
}

# ---------- phase 5: assemble dynamic prompt ----------
phase5_assemble_prompt() {
  log "== Phase 7/10: assemble dynamic system prompt"
  if [ "$CHECK_ONLY" -eq 1 ]; then
    log "  [check] would assemble prompts/system.md from core + manifest + memory + preflight + history"
    phase_result "−" "prompt assembly (check mode)"; return
  fi
  chmod +x "$REPO_ROOT/scripts/assemble-prompt.sh"
  local out
  out="$(bash "$REPO_ROOT/scripts/assemble-prompt.sh" 2>&1)" \
    || die "prompt assembly" "scripts/assemble-prompt.sh failed: $out"
  log "  $out"
  phase_result "✓" "dynamic prompt assembled"
}

# ---------- phase 5b: opencode <-> anthropic wiring ----------
phase5b_wiring() {
  log "== Phase 8/10: opencode config wiring"
  FABLE_PROXY_PORT="${FABLE_PROXY_PORT:-8377}"
  if [ "$CHECK_ONLY" -eq 1 ]; then
    log "  [check] would merge opencode.json (provider=anthropic via proxy :$FABLE_PROXY_PORT)"
    phase_result "−" "wiring (check mode)"; return
  fi
  # resolve model: explicit FABLE_MODEL > dynamic lookup by FABLE_MODEL_TIER > default
  local resolved_model
  if [ -n "${FABLE_MODEL:-}" ]; then
    resolved_model="$FABLE_MODEL"
    log "  model override: $resolved_model"
  else
    local tier="${FABLE_MODEL_TIER:-sonnet}"
    log "  querying Anthropic for newest $tier model..."
    resolved_model="$("$PYTHON" - "$tier" <<'PYMODEL'
import json, sys, urllib.request
tier = sys.argv[1]
req = urllib.request.Request(
    "https://api.anthropic.com/v1/models?limit=100",
    headers={"x-api-key": __import__("os").environ["ANTHROPIC_API_KEY"],
             "anthropic-version": "2023-06-01"})
data = json.loads(urllib.request.urlopen(req, timeout=10).read())
candidates = [m for m in data.get("data", []) if tier in m["id"]]
candidates.sort(key=lambda m: m.get("created_at", ""), reverse=True)
if candidates:
    print(candidates[0]["id"])
else:
    print(f"claude-{tier}-4-5")
PYMODEL
    )" || resolved_model="claude-sonnet-4-5"
    log "  resolved model: $resolved_model"
  fi

  "$PYTHON" - "$REPO_ROOT/opencode.json" "$FABLE_PROXY_PORT" "$resolved_model" <<'PY'
import json, os, sys
path, port, model = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        cfg = json.load(f)
cfg["$schema"] = "https://opencode.ai/config.json"

# provider: anthropic via audit proxy
prov = cfg.setdefault("provider", {}).setdefault("anthropic", {}).setdefault("options", {})
prov["baseURL"] = f"http://127.0.0.1:{port}"
prov["apiKey"] = "{env:ANTHROPIC_API_KEY}"

# fable agent owns the model — no top-level "model" key needed
cfg.pop("model", None)

# agent: fable — primary agent with system prompt and all tools
cfg["agent"] = {
    "fable": {
        "description": "Fable: careful, repo-native coding agent with SOC 2 audit logging",
        "mode": "primary",
        "model": f"anthropic/{model}",
        "prompt": "{file:./prompts/system.md}",
        "permission": {
            "read": "allow",
            "edit": "allow",
            "grep": "allow",
            "glob": "allow",
            "webfetch": "allow",
            "todowrite": "allow",
            "question": "allow",
            "skill": "allow",
            "bash": "ask",
        },
    }
}
cfg["default_agent"] = "fable"

# global permissions (fallback for non-agent context)
cfg["permission"] = {
    "read": "allow",
    "edit": "allow",
    "grep": "allow",
    "glob": "allow",
    "webfetch": "allow",
    "todowrite": "allow",
    "question": "allow",
    "skill": "allow",
    "bash": "ask",
}

# remove stale instructions key (prompt is in agent config now)
cfg.pop("instructions", None)

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"  wrote {path} (default_agent=fable, model=anthropic/{model}, baseURL=http://127.0.0.1:{port})")
PY
  phase_result "✓" "opencode wired to anthropic via audit proxy"
}

# ---------- phase 6: audit proxy ----------
phase6_proxy() {
  log "== Phase 9/10: audit proxy"
  FABLE_PROXY_PORT="${FABLE_PROXY_PORT:-8377}"
  FABLE_AUDIT_DIR="${FABLE_AUDIT_DIR:-$FABLE_HOME/audit}"
  if [ "$CHECK_ONLY" -eq 1 ]; then
    log "  [check] would start proxy on 127.0.0.1:$FABLE_PROXY_PORT, audit dir $FABLE_AUDIT_DIR"
    phase_result "−" "proxy (check mode)"; return
  fi
  mkdir -p "$FABLE_HOME" "$FABLE_AUDIT_DIR"
  chmod 700 "$FABLE_HOME" "$FABLE_AUDIT_DIR"

  local pidfile="$FABLE_HOME/proxy.pid"
  local env_file="$REPO_ROOT/.env"
  local proxy_args="--port $FABLE_PROXY_PORT --env-file $env_file"
  # If key isn't set yet, tell the proxy to open /setup in the browser
  if [ -z "${ANTHROPIC_API_KEY:-}" ] || [ "${ANTHROPIC_API_KEY:-}" = "sk-ant-your-key-here" ]; then
    proxy_args="$proxy_args --open-setup"
  fi
  FABLE_AUDIT_DIR="$FABLE_AUDIT_DIR" \
  FABLE_AUDIT_STRICT="${FABLE_AUDIT_STRICT:-0}" \
  FABLE_AUDIT_RETENTION_DAYS="${FABLE_AUDIT_RETENTION_DAYS:-365}" \
  nohup "$PYTHON" "$REPO_ROOT/proxy/audit_proxy.py" $proxy_args \
    >> "$FABLE_HOME/proxy.out" 2>&1 &
  echo $! > "$pidfile"

  local i
  for i in $(seq 1 20); do
    if curl -fsS "http://127.0.0.1:$FABLE_PROXY_PORT/healthz" >/dev/null 2>&1; then
      log "  proxy healthy on 127.0.0.1:$FABLE_PROXY_PORT (pid $(cat "$pidfile"))"
      phase_result "✓" "audit proxy started"
      return
    fi
    sleep 0.25
  done
  die "audit proxy" "proxy failed health check; see $FABLE_HOME/proxy.out"
}

# ---------- phase 7: smoke test ----------
phase7_smoke() {
  log "== Phase 10/10: smoke test through proxy"
  if [ "$CHECK_ONLY" -eq 1 ]; then
    log "  [check] would send 1 message through proxy and assert audit capture"
    phase_result "−" "smoke (check mode)"; return
  fi
  FABLE_AUDIT_DIR="${FABLE_AUDIT_DIR:-$FABLE_HOME/audit}"
  local status before after
  before="$(cat "$FABLE_AUDIT_DIR"/audit-*.jsonl 2>/dev/null | wc -l)"
  status="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "{\"model\":\"${FABLE_MODEL:-claude-sonnet-4-5}\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"smoke: reply ok\"}]}" \
    "http://127.0.0.1:${FABLE_PROXY_PORT:-8377}/v1/messages")"
  [ "$status" = "200" ] || die "smoke test" "proxied request failed: HTTP $status"
  after="$(cat "$FABLE_AUDIT_DIR"/audit-*.jsonl 2>/dev/null | wc -l)"
  [ "$after" -gt "$before" ] || die "smoke test" "request succeeded but no audit events were written"

  # end-to-end smoke through the real fable binary: exercises the Go SDK's
  # request construction (params, timeouts), not just raw HTTP like curl.
  # this is what caught nothing when curl passed but the SDK sent
  # unsupported params (e.g. temperature on claude-sonnet-4-5).
  log "  running end-to-end smoke via fable binary..."
  local e2e_out
  if e2e_out="$(ANTHROPIC_BASE_URL="http://127.0.0.1:${FABLE_PROXY_PORT:-8377}" \
      timeout 90 "$OPENCODE_BIN" -p "smoke test: reply with the single word ok" -q -f text 2>&1)"; then
    log "  e2e smoke OK: $(echo "$e2e_out" | head -1 | cut -c1-60)"
  else
    die "smoke test" "end-to-end fable run failed: $(echo "$e2e_out" | tail -3)"
  fi

  # secret-leak check: raw key must not appear anywhere under FABLE_HOME
  if grep -rqF "$ANTHROPIC_API_KEY" "$FABLE_HOME" 2>/dev/null; then
    die "smoke test" "RAW API KEY FOUND in $FABLE_HOME — redaction failure, do not proceed"
  fi
  # hash chain integrity
  "$PYTHON" "$REPO_ROOT/bin/fable-audit" verify >/dev/null \
    || die "smoke test" "audit hash-chain verification failed"
  # API error scan: any 4xx/5xx captured during smoke is a config/SDK bug
  if "$PYTHON" "$REPO_ROOT/bin/fable-audit" errors --quiet 2>/dev/null; then
    :
  else
    log "  WARNING: API errors found in audit log — run ./bin/fable-audit errors"
  fi
  log "  proxied request OK, $((after - before)) audit events captured, e2e verified, no key leakage, chain verified"
  phase_result "✓" "smoke test"
}

# ---------- state ----------
write_state() {
  [ "$CHECK_ONLY" -eq 1 ] && return 0
  mkdir -p "$FABLE_HOME"
  "$PYTHON" - "$STATE_FILE" "${OC_VERSION:-unknown}" "$OC_TARGET" "$FORM_FACTOR" <<'PY'
import json, sys, datetime
path, ver, target, ff = sys.argv[1:5]
json.dump({"opencode_version": ver, "target": target, "form_factor": ff,
           "last_bootstrap_utc": datetime.datetime.now(datetime.timezone.utc).isoformat()},
          open(path, "w"), indent=2)
PY
}

main() {
  log "fable-up: bootstrap starting (check=$CHECK_ONLY)"
  phase0_cleanup
  phase1_platform
  phase1b_python
  phase2_opencode
  phase6_proxy           # proxy starts early so /setup is available for key entry
  phase3_credentials     # polls proxy /healthz for key_configured if needed
  phase4_warmup
  phase5_assemble_prompt
  phase5b_wiring
  phase7_smoke
  write_state
  print_summary
  log ""
  log "Audit CLI: ./bin/fable-audit tail | verify | export | rotate | tokens"
  if [ "$CHECK_ONLY" -eq 1 ]; then
    log "Done (check mode). Run ./bootstrap.sh to provision for real."
  else
    log "Launching Fable..."
    export ANTHROPIC_BASE_URL="http://127.0.0.1:${FABLE_PROXY_PORT:-8377}"
    exec "$OPENCODE_BIN"
  fi
}
main
