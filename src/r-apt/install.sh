#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2012,SC2015,SC2016,SC2034,SC2119,SC2120,SC2317
# =====================================================================
# janus install.sh - VPS first-hop multi-protocol management console v1.0
# ---------------------------------------------------------------------
# Project:  janus
# Purpose:    Deploys a multi-protocol VPN egress on Debian 11+ / Ubuntu 22.04+ with a single command
# Protocols:    13 fixed protocols(Xray 8 + sing-box 5)
#          R-VLESS-Vision / R-VLESS-XHTTP / R-VLESS-gRPC
#          C-VLESS-XHTTP / C-VLESS-WS / C-Trojan-WS / C-VMess-WS / C-VLESS-HTTPUpgrade
#          U-Hysteria2 / U-TUIC-v5
#          D-AnyTLS / D-NaiveProxy / D-ShadowTLS-SS
# Constraints:    single file / one-line launcher / English UI text / no external templates / no second-hop credentials
#          does not support v2ray-core / trojan-go / Hy v1 / mKCP / TCP-TLS / VMess-TCP
# Acknowledgements:    v2ray-agent (mack-a) / acme.sh / Xray-core / sing-box / cloudflared
# one-line launcher:  bash <(curl -fsSL https://raw.githubusercontent.com/cairn-lab-472/devcontainer-features/main/src/r-apt/install.sh)
# =====================================================================

# ============ SECTION 00 Shebang / error handling and traps ============
set -Eeuo pipefail
IFS=$'\n\t'

# Enable debug mode with JANUS_DEBUG=1
[[ "${JANUS_DEBUG:-0}" == "1" ]] && set -x

# Register global traps. onErr / onExit are defined after SECTION 02,
# so wrapper functions are used here to avoid trap registration failures before those functions exist.
__on_err_proxy() { onErr "$1" "$2" "$3"; }
__on_exit_proxy() { onExit "$1"; }
trap '__on_err_proxy $? $LINENO "$BASH_COMMAND"' ERR
trap '__on_exit_proxy $?' EXIT

# ============ SECTION 01 constant declarations ============
readonly NS="janus"
readonly VERSION="1.0"
readonly WORKDIR="/etc/janus"
readonly WEBROOT="/var/lib/janus/web"
readonly BACKUP_DIR="/var/lib/janus/backups"
readonly TOOLS_DIR="/etc/janus/tools"
readonly STATE_FILE="/etc/janus/state.json"
readonly STATE_LOCK="/var/run/janus-state.lock"
readonly CLI_PATH="/usr/local/bin/janus"
readonly INSTALL_SH_DEST="/etc/janus/install.sh"

readonly CERT_DIR="/etc/janus/cert"
readonly CERT_FULLCHAIN="${CERT_DIR}/fullchain.pem"
readonly CERT_KEY="${CERT_DIR}/privkey.pem"

readonly XRAY_DIR="/etc/janus/xray"
readonly XRAY_CONFIG="${XRAY_DIR}/config.json"
readonly XRAY_BIN="/usr/local/bin/xray"

readonly SBOX_DIR="/etc/janus/sbox"
readonly SBOX_CONFIG="${SBOX_DIR}/config.json"
readonly SBOX_BIN="/usr/local/bin/sing-box"

readonly CFD_DIR="/etc/janus/cloudflared"
readonly CFD_TOKEN_FILE="${CFD_DIR}/token"
readonly CFD_CONFIG_FILE="${CFD_DIR}/config.yml"
readonly CFD_BIN="/usr/local/bin/cloudflared"

readonly CF_TOKEN_FILE="/etc/janus/cf_token"
readonly SNI_EXTRA_FILE="/etc/janus/sni-extra.txt"
readonly CFST_BIN="${TOOLS_DIR}/CloudflareST"
readonly CFST_RESULT_FILE="${TOOLS_DIR}/cfst-result.csv"
readonly CFST_IP_FILE="${TOOLS_DIR}/ip.txt"
readonly CFST_IPV6_FILE="${TOOLS_DIR}/ipv6.txt"
readonly REALITLS_BIN="${TOOLS_DIR}/RealiTLScanner"

readonly REPO_RAW_URL="${JANUS_REPO_RAW_URL:-https://raw.githubusercontent.com/cairn-lab-472/devcontainer-features/main/src/r-apt}"
readonly INSTALL_SH_URL="${REPO_RAW_URL}/install.sh"

# Known fallback sing-box version with the naive tag; installSingBox falls back to it if self-tests fail
readonly SBOX_FALLBACK_TAG_WITH_NAIVE="v1.11.15"

# systemd unit names
readonly UNIT_XRAY="janus-xray.service"
readonly UNIT_SBOX="janus-singbox.service"
readonly UNIT_CFD="janus-cloudflared.service"
readonly UNIT_SUB="janus-sub.service"
readonly UNIT_HOP="janus-hop.service"
readonly UNIT_SNI_S="janus-sni-rotate.service"
readonly UNIT_SNI_T="janus-sni-rotate.timer"
readonly UNIT_CFST_S="janus-cfst.service"
readonly UNIT_CFST_T="janus-cfst.timer"
readonly UNIT_ACME_S="janus-acme-renew.service"
readonly UNIT_ACME_T="janus-acme-renew.timer"
readonly ALL_UNITS=("$UNIT_XRAY" "$UNIT_SBOX" "$UNIT_CFD" "$UNIT_SUB" "$UNIT_HOP" "$UNIT_SNI_S" "$UNIT_SNI_T" "$UNIT_CFST_S" "$UNIT_CFST_T" "$UNIT_ACME_S" "$UNIT_ACME_T")

# Subdomain conventions
SUB_R="r"      # Reality direct-entry subdomain
SUB_CDN="cdn"  # CDN/Tunnel entry subdomain
SUB_SUB="sub"  # subscription delivery subdomain

readonly DARKHTTPD_PORT_DEFAULT=18470

# ============ SECTION 02 colors and logging ============
__use_color() {
  [[ "${NO_COLOR:-0}" != "1" ]]
}
__c() {
  # $1: ANSI code; $2: text
  if __use_color; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi
}

CLR_BORDER='1;31'
CLR_SECTION='1;36'
CLR_MENU='1;33'
CLR_OK='1;32'
CLR_WARN='1;33'
CLR_ERR='1;31'
CLR_INFO='1;37'

# informational message
log()    { printf '%s %s\n' "$(__c "$CLR_SECTION" '[INFO]')" "$*"; }
# success
ok()     { printf '%s %s\n' "$(__c "$CLR_OK" '[OK]')" "$*"; }
# warning
warn()   { printf '%s %s\n' "$(__c "$CLR_WARN" '[WARN]')" "$*" >&2; }
# error
err()    { printf '%s %s\n' "$(__c "$CLR_ERR" '[ERR]')" "$*" >&2; }
# fatal: print an error and exit
die()    { err "$*"; exit 1; }
# banner: section title
banner() {
  local title="$*"
  local bar="==========================================================="
  printf '\n%s\n%s  %s\n%s\n' "$(__c "$CLR_BORDER" "$bar")" "$(__c "$CLR_SECTION" '::')" "$(__c "$CLR_INFO" "$title")" "$(__c "$CLR_BORDER" "$bar")"
}
# step: print a numbered step
step()   { printf '%s %s\n' "$(__c '1;35' '[STEP]')" "$*"; }

menuPause() {
  read -r -p "$(__c "$CLR_MENU" 'Press Enter to continue...')" _ || true
}

menuInvoke() {
  local rc old_errexit old_ctx
  old_ctx="${JANUS_MENU_CONTEXT:-0}"
  JANUS_MENU_CONTEXT=1
  old_errexit=$(case "$-" in *e*) echo 1 ;; *) echo 0 ;; esac)
  set +e
  if ( set +e; "$@" ); then
    rc=0
  else
    rc=$?
  fi
  (( old_errexit )) && set -e
  JANUS_MENU_CONTEXT="$old_ctx"
  if (( rc != 0 )); then
    warn "The operation did not complete; returning to the menu."
  fi
  return 0
}

menuLine() {
  printf '  %s\n' "$(__c "$CLR_MENU" "$*")"
}

# interactive input prompt
prompt() {
  local var=$1 msg=$2 def="${3:-}"
  local val
  if [[ -n "$def" ]]; then
    read -r -p "$msg [$def]: " val || true
    val="${val:-$def}"
  else
    read -r -p "$msg: " val || true
  fi
  printf -v "$var" '%s' "$val"
}

confirm() {
  local msg=$1
  local ans
  read -r -p "$msg [y/N]: " ans || true
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ============ SECTION 03 common utility functions ============
# need: require commands to exist, otherwise die
need() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
  done
}
# have: whether a command exists(bool)
have() { command -v "$1" >/dev/null 2>&1; }

# retry: retry N delay -- cmd args
retry() {
  local n=$1 delay=$2; shift 2
  local i=0
  until "$@"; do
    i=$((i+1))
    if (( i >= n )); then
      return 1
    fi
    sleep "$delay"
  done
}

# jqset: modify a JSON key in place
jqset() {
  local file=$1 expr=$2
  local tmp; tmp="$(mktemp)"
  jq "$expr" "$file" > "$tmp"
  mv "$tmp" "$file"
}

# pwgen: generate a password of length N(base64 characters)
pwgen() {
  local n="${1:-32}"
  openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c "$n"
}

# randPort: generate a random port from 1025 to 65000
randPort() {
  local p
  while :; do
    p=$(( (RANDOM<<15 | RANDOM) % 64000 + 1025 ))
    if ! ss -tlnH "sport = :$p" 2>/dev/null | grep -q . && \
       ! ss -ulnH "sport = :$p" 2>/dev/null | grep -q .; then
      printf '%s' "$p"; return 0
    fi
  done
}

# httpProbe: curl status-code probe
httpProbe() {
  local url=$1
  # Do not use -f: for 4xx/5xx responses it prints "curl: (22) ..." to stderr and exits non-zero,
  # which would make `|| echo 000` append "000" after a real HTTP status code was already printed.
  curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000"
}

# tlsProbe: openssl probe the TLS handshake
tlsProbe() {
  local host=$1 port="${2:-443}"
  timeout 6 openssl s_client -connect "${host}:${port}" -servername "$host" \
    -alpn h2 -tls1_3 -brief </dev/null 2>&1
}

# githubLatestTag: fetch the latest release tag from GitHub
githubLatestTag() {
  local repo=$1
  local out
  out=$(retry 3 2 curl -fsSL --max-time 15 "https://api.github.com/repos/${repo}/releases/latest") || return 1
  jq -r '.tag_name // empty' <<<"$out"
}

# output the binary architecture keyword for the current host
hostArch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "unsupported architecture: $(uname -m)";;
  esac
}

# ============ SECTION 04 state.json and environment variables ============
# state schema defaults (merged and backfilled by loadState)
__state_defaults() {
  cat <<'EOF'
{
  "schema_version": 1,
  "ns": "janus",
  "install_step": 0,
  "domain": "",
  "acme_email": "",
  "ipv4": "",
  "ipv6": "",
  "uuid": "",
  "sub_token": "",
  "reality_privkey": "",
  "reality_pubkey": "",
  "reality_shortid": "",
  "reality_sni": "www.cisco.com",
  "last_known_good_sni": "",
  "sni_override": null,
  "sni_auto_rotate": true,
  "sni_dry_run": false,
  "sni_grace_server_names": [],
  "sni_history": {},
  "reality_mldsa65_enabled": false,
  "reality_mldsa65_seed": "",
  "reality_mldsa65_verify": "",
  "xhttp_path": "/xh",
  "grpc_service_name": "grpc",
  "hy2_obfs_password": "",
  "tuic_password": "",
  "shadowtls_password": "",
  "shadowtls_ss_method": "2022-blake3-aes-128-gcm",
  "shadowtls_ss_password": "",
  "cf_account_id": "",
  "cf_zone_id": "",
  "cf_tunnel_id": "",
  "cf_tunnel_name": "",
  "acme_ca": "letsencrypt",
  "proto_enabled": ["R-VLESS-Vision"],
  "proto_port_override": {},
  "sub_include_naive_mihomo": false,
  "sub_darkhttpd_port": 18470,
  "cfst_enabled": false,
  "cfst_best_ip": "",
  "cfst_best_region": "",
  "cfst_best_speed": "",
  "cfst_updated_at": "",
  "alert": null,
  "ports": {},
  "created_at": "",
  "updated_at": ""
}
EOF
}

# loadState: load state.json; initialize it with defaults if it does not exist
loadState() {
  # loadState is often guarded by `if ! loadState`, so the menu can still start when state.json is empty or broken.
  # Temporarily disable errexit here and return rc explicitly, to prevent the global ERR trap from exiting first when state is corrupted.
  local old_errexit=0 rc=0
  case "$-" in *e*) old_errexit=1; set +e ;; esac
  mkdir -p "$WORKDIR"
  local state_dir; state_dir=$(dirname "$STATE_FILE")
  (
    flock 9
    local tmp defaults current merged
    if [[ ! -f "$STATE_FILE" ]]; then
      tmp=$(mktemp "${state_dir}/.state.XXXXXX") || exit 1
      if ! __state_defaults | jq '.created_at = (now|todate) | .updated_at = (now|todate)' > "$tmp"; then
        rm -f "$tmp"
        exit 1
      fi
      chmod 600 "$tmp" || { rm -f "$tmp"; exit 1; }
      mv -f "$tmp" "$STATE_FILE" || { rm -f "$tmp"; exit 1; }
      return 0
    fi
    if [[ ! -s "$STATE_FILE" ]]; then
      warn "state.json is empty; refusing to overwrite it with defaults. Restore it from a backup: $STATE_FILE"
      return 1
    fi
    if ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
      warn "state.json is not valid JSON; refusing schema merge. Fix it or restore a backup first: $STATE_FILE"
      return 1
    fi
    # Schema upgrade: merge missing fields. Read, merge, and write must happen under the same lock,
    # tmp is placed in the same directory as state, so mv is an atomic replacement on the same filesystem.
    defaults=$(__state_defaults) || return 1
    current=$(cat "$STATE_FILE") || return 1
    merged=$(jq -n --argjson d "$defaults" --argjson c "$current" '$d * $c') || return 1
    merged=$(printf '%s' "$merged" | jq 'del(.proto_disabled) | del(.reality_mldsa65_mode)') || return 1
    [[ -n "$merged" ]] || return 1
    tmp=$(mktemp "${state_dir}/.state.XXXXXX") || return 1
    printf '%s' "$merged" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$STATE_FILE" || { rm -f "$tmp"; return 1; }
  ) 9>"$STATE_LOCK" || rc=$?
  (( old_errexit )) && set -e
  return "$rc"
}

# stateGet: read a scalar field; return an empty string if missing
stateGet() {
  local key=$1
  [[ -f "$STATE_FILE" ]] || { printf ''; return 0; }
  # Use `if . == null` instead of `// ""`: jq's `//` falls back on both null and false,
  # would convert a valid boolean such as `cfst_enabled=false` into an empty string, which breaks the header display.
  jq -r --arg k "$key" '
    (.[$k]) as $v
    | (if $v == null then "" else $v end)
    | if type=="boolean" or type=="number" then tostring else . end
  ' "$STATE_FILE"
}

# stateGetJson: read a field of any type and return JSON
stateGetJson() {
  local key=$1
  [[ -f "$STATE_FILE" ]] || { printf 'null'; return 0; }
  jq -c --arg k "$key" '.[$k] // null' "$STATE_FILE"
}

# stateSet: write a string field(with flock)
stateSet() {
  local key=$1 val=$2
  __state_lock_run jq --arg k "$key" --arg v "$val" \
    '.[$k]=$v | .updated_at=(now|todate)' "$STATE_FILE"
}

# stateSetJson: write a JSON field
stateSetJson() {
  local key=$1 json=$2
  __state_lock_run jq --arg k "$key" --argjson v "$json" \
    '.[$k]=$v | .updated_at=(now|todate)' "$STATE_FILE"
}

# stateMerge: merge multiple fields with a JSON patch
stateMerge() {
  local patch=$1
  __state_lock_run jq --argjson p "$patch" '. * $p | .updated_at=(now|todate)' "$STATE_FILE"
}

# saveState: only refresh updated_at(saveState idempotency is handled by the caller)
saveState() {
  __state_lock_run jq '.updated_at=(now|todate)' "$STATE_FILE"
}

randUrlsafe() {
  local bytes="${1:-24}"
  openssl rand -base64 "$bytes" | tr '+/' '-_' | tr -d '=\n'
}

randB64() {
  local bytes="${1:-16}"
  openssl rand -base64 "$bytes" | tr -d '\n'
}

cdnPath() {
  case "$1" in
    C-VLESS-XHTTP)       printf '/assets/vx3/manifest' ;;
    C-VLESS-WS)          printf '/assets/vw2/sync' ;;
    C-Trojan-WS)         printf '/assets/tw2/status' ;;
    C-VMess-WS)          printf '/assets/mw2/media' ;;
    C-VLESS-HTTPUpgrade) printf '/assets/vu2/check' ;;
    *) return 1 ;;
  esac
}

cdnPathGlob() {
  printf '%s*' "$(cdnPath "$1")"
}

stateEnsureProtocolSecrets() {
  local v
  v=$(stateGet xhttp_path); [[ -n "$v" ]] || stateSet xhttp_path "/xh"
  v=$(stateGet grpc_service_name); [[ -n "$v" ]] || stateSet grpc_service_name "grpc"
  v=$(stateGet hy2_obfs_password); [[ -n "$v" ]] || stateSet hy2_obfs_password "$(randUrlsafe 16)"
  v=$(stateGet tuic_password); [[ -n "$v" ]] || stateSet tuic_password "$(randUrlsafe 24)"
  v=$(stateGet shadowtls_password); [[ -n "$v" ]] || stateSet shadowtls_password "$(randUrlsafe 24)"
  v=$(stateGet shadowtls_ss_method); [[ -n "$v" ]] || stateSet shadowtls_ss_method "2022-blake3-aes-128-gcm"
  v=$(stateGet shadowtls_ss_password); [[ -n "$v" ]] || stateSet shadowtls_ss_password "$(randB64 16)"
}

# requireState: require a non-empty state field; die on failure
requireState() {
  local key=$1 val
  val=$(stateGet "$key")
  [[ -n "$val" && "$val" != "null" ]] || die "state.${key} is missing; run the corresponding initialization menu first"
}

# internal: atomically replace state.json under flock protection
__state_lock_run() {
  local state_dir tmp rc=0
  state_dir=$(dirname "$STATE_FILE")
  tmp="$(mktemp "${state_dir}/.state.XXXXXX")"
  # Cleanup trap inside the subshell: if jq or mv fails, no .state.XXXXXX file is left in $state_dir.
  (
    trap 'rm -f "$tmp"' EXIT
    flock 9
    if "$@" > "$tmp"; then
      mv "$tmp" "$STATE_FILE"
    else
      rc=$?
      rm -f "$tmp"
      exit "$rc"
    fi
  ) 9>"$STATE_LOCK" || rc=$?
  return "$rc"
}

# requireEnv: validate the three core environment variables; fill them interactively
requireEnv() {
  local need_save=0
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    if [[ -f "$CF_TOKEN_FILE" ]]; then
      CF_API_TOKEN=$(<"$CF_TOKEN_FILE")
    fi
  fi
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    prompt CF_API_TOKEN "Enter the Cloudflare API Token"
    [[ -n "$CF_API_TOKEN" ]] || die "CF_API_TOKEN was not provided"
    need_save=1
  fi
  export CF_API_TOKEN
  local existing_token=""
  [[ -r "$CF_TOKEN_FILE" ]] && existing_token=$(cat "$CF_TOKEN_FILE")
  if (( need_save )) || [[ "$existing_token" != "$CF_API_TOKEN" ]]; then
    mkdir -p "$WORKDIR"
    printf '%s' "$CF_API_TOKEN" > "$CF_TOKEN_FILE"
    chmod 600 "$CF_TOKEN_FILE"
  fi

  if [[ -z "${ROOT_DOMAIN:-}" ]]; then
    ROOT_DOMAIN=$(stateGet domain)
  fi
  if [[ -z "${ROOT_DOMAIN:-}" ]]; then
    prompt ROOT_DOMAIN "Enter the root domain(must be hosted on Cloudflare)"
    [[ -n "$ROOT_DOMAIN" ]] || die "ROOT_DOMAIN was not provided"
  fi
  export ROOT_DOMAIN
  stateSet domain "$ROOT_DOMAIN"

  if [[ -z "${ACME_EMAIL:-}" ]]; then
    ACME_EMAIL=$(stateGet acme_email)
  fi
  if [[ -z "${ACME_EMAIL:-}" ]]; then
    prompt ACME_EMAIL "Enter the ACME email address(used for Let's Encrypt registration)"
    [[ -n "$ACME_EMAIL" ]] || die "ACME_EMAIL was not provided"
  fi
  export ACME_EMAIL
  stateSet acme_email "$ACME_EMAIL"
}

# ============ SECTION 05 system checks, dependencies, and kernel tuning ============
checkRoot() {
  [[ "$EUID" -eq 0 ]] || die "must be run as root"
}

checkOS() {
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
  local id ver
  id=$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2}' /etc/os-release)
  ver=$(awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2); print $2}' /etc/os-release)
  case "$id" in
    debian)
      [[ "${ver%%.*}" -ge 11 ]] || die "Debian 11+ is required(current $ver)"
      ;;
    ubuntu)
      local maj; maj="${ver%%.*}"
      [[ "$maj" -ge 22 ]] || die "Ubuntu 22.04+ is required(current $ver)"
      ;;
    *)
      die "only Debian / Ubuntu is supported(current $id)"
      ;;
  esac
  ok "System check passed: $id $ver"
}

requiredAptPkgs() {
  # Keep this list in sync with requiredCommands(). These are the packages needed by
  # the installer, generated systemd units, diagnostics, QR output, and subscription serving.
  cat <<'EOF'
curl
jq
qrencode
openssl
iptables
socat
cron
ca-certificates
xz-utils
tar
unzip
gawk
bind9-dnsutils
netcat-openbsd
iproute2
procps
util-linux
coreutils
EOF
}

requiredCommands() {
  cat <<'EOF'
curl
jq
qrencode
openssl
iptables
ip6tables
socat
crontab
tar
unzip
awk
dig
nc
ss
sysctl
flock
timeout
EOF
}

depsMissingPackages() {
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    dpkg -s "$p" 2>/dev/null | grep -q '^Status: install ok installed$' || printf '%s\n' "$p"
  done < <(requiredAptPkgs)
}

depsMissingCommands() {
  local c
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    command -v "$c" >/dev/null 2>&1 || printf '%s\n' "$c"
  done < <(requiredCommands)
}

depsAllInstalled() {
  [[ -z "$(depsMissingPackages)" && -z "$(depsMissingCommands)" ]]
}

installDeps() {
  local miss=()
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    dpkg -s "$p" 2>/dev/null | grep -q '^Status: install ok installed$' || miss+=("$p")
  done < <(requiredAptPkgs)

  if (( ${#miss[@]} > 0 )); then
    log "Installing missing dependencies: ${miss[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${miss[@]}"
  fi

  local missing_pkgs missing_cmds
  missing_pkgs=$(depsMissingPackages || true)
  missing_cmds=$(depsMissingCommands || true)
  if [[ -n "$missing_pkgs" || -n "$missing_cmds" ]]; then
    [[ -z "$missing_pkgs" ]] || err "Missing apt packages after install: $(tr '\n' ' ' <<<"$missing_pkgs")"
    [[ -z "$missing_cmds" ]] || err "Missing commands after install: $(tr '\n' ' ' <<<"$missing_cmds")"
    die "Dependency verification failed"
  fi

  ok "Dependencies are installed and verified"
}

kernelTune() {
  local f="/etc/sysctl.d/99-janus.conf"
  cat > "$f" <<'EOF'
# janus kernel tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 8388608
net.core.wmem_default = 8388608
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
fs.file-max = 1048576
EOF
  sysctl --system >/dev/null
  ok "Kernel parameters have been applied"
}

# detect public IPv4/IPv6
detectPublicIp() {
  local v4 v6
  v4=$(curl -fsS --max-time 6 -4 https://api.ipify.org 2>/dev/null || true)
  v6=$(curl -fsS --max-time 6 -6 https://api64.ipify.org 2>/dev/null || true)
  [[ -n "$v4" ]] && stateSet ipv4 "$v4"
  [[ -n "$v6" ]] && stateSet ipv6 "$v6"
  log "Public IPv4=${v4:-not detected}  IPv6=${v6:-not detected}"
}

# ============ SECTION 06 firewall orchestration ============
__detect_ssh_port() {
  local p
  p=$(ss -tlnp 2>/dev/null | awk '/sshd/{print $4}' | awk -F: '{print $NF}' | sort -u | head -n1)
  [[ -z "$p" ]] && p=22
  printf '%s' "$p"
}

moduleFirewall() {
  banner "System firewall check"
  if have ufw; then
    if ufw status 2>/dev/null | grep -qi '^Status: active'; then
      warn 'Detected active ufw (not configured by this script). If its rules block 443/8443/2053/8444/9443/10443/tcp, 4433/11443/udp, or the hop UDP range, allow them manually or run `ufw disable` to restore the default pass-through behavior.'
    fi
  fi
  return 0
}

# ============ SECTION 07 Cloudflare API helper functions ============
readonly CF_API_BASE="https://api.cloudflare.com/client/v4"

# __cfAuthHeaderFile: write the "Authorization: Bearer ..." line to a 0600 tmp file
# and print its path. Why: putting the token in curl argv exposes it via
# /proc/<pid>/cmdline, and `set -x` (JANUS_DEBUG=1) would also trace it.
# `local -` scopes shell options to this function, so the temporary `set +x`
# does not leak xtrace state back to the caller.
__cfAuthHeaderFile() {
  local -
  set +x
  local hfile
  hfile=$(mktemp) || return 1
  chmod 600 "$hfile" 2>/dev/null || true
  printf 'Authorization: Bearer %s\n' "$CF_API_TOKEN" > "$hfile" || { rm -f "$hfile"; return 1; }
  printf '%s' "$hfile"
}

# cfApi <method> <path> [json-body]
# Output JSON; on failure, return non-zero and print Cloudflare errors
cfApi() {
  local method=$1 path=$2 body="${3:-}"
  local resp hfile
  hfile=$(__cfAuthHeaderFile) || { err "Cloudflare API call failed: could not prepare auth header"; return 1; }
  if [[ -n "$body" ]]; then
    resp=$(curl -fsS --max-time 20 -X "$method" \
      -H "@${hfile}" \
      -H "Content-Type: application/json" \
      --data "$body" \
      "${CF_API_BASE}${path}" 2>/dev/null || true)
  else
    resp=$(curl -fsS --max-time 20 -X "$method" \
      -H "@${hfile}" \
      "${CF_API_BASE}${path}" 2>/dev/null || true)
  fi
  rm -f "$hfile"
  if [[ -z "$resp" ]]; then
    err "Cloudflare API call failed: $method $path"
    return 1
  fi
  local success; success=$(jq -r '.success // false' <<<"$resp")
  if [[ "$success" != "true" ]]; then
    err "Cloudflare API returned an error: $method $path"
    jq -r '.errors[]? | "  code=\(.code) msg=\(.message)"' <<<"$resp" >&2 || true
    return 1
  fi
  printf '%s' "$resp"
}

cfZoneId() {
  local domain="${1:-$ROOT_DOMAIN}"
  local cached; cached=$(stateGet cf_zone_id)
  if [[ -n "$cached" ]]; then
    printf '%s' "$cached"; return 0
  fi
  local resp; resp=$(cfApi GET "/zones?name=${domain}")
  local zid; zid=$(jq -r '.result[0].id // empty' <<<"$resp")
  [[ -n "$zid" ]] || die "zone not found: $domain(confirm the domain is hosted on Cloudflare)"
  stateSet cf_zone_id "$zid"
  printf '%s' "$zid"
}

cfAccountId() {
  local cached; cached=$(stateGet cf_account_id)
  if [[ -n "$cached" ]]; then
    printf '%s' "$cached"; return 0
  fi
  local resp; resp=$(cfApi GET "/accounts?per_page=1")
  local aid; aid=$(jq -r '.result[0].id // empty' <<<"$resp")
  [[ -n "$aid" ]] || die "Cloudflare account ID not found"
  stateSet cf_account_id "$aid"
  printf '%s' "$aid"
}

# cfRecordGet <name> <type>
# output the record ID(empty if missing)
cfRecordGet() {
  local name=$1 type=$2
  local zid; zid=$(cfZoneId)
  local resp; resp=$(cfApi GET "/zones/${zid}/dns_records?type=${type}&name=${name}")
  jq -r '.result[0].id // empty' <<<"$resp"
}

# cfRecordUpsert <name> <type> <content> <proxied:true|false> [ttl]
cfRecordUpsert() {
  local name=$1 type=$2 content=$3 proxied=$4 ttl="${5:-1}"
  local zid; zid=$(cfZoneId)
  local rid; rid=$(cfRecordGet "$name" "$type")
  local body
  body=$(jq -n --arg n "$name" --arg t "$type" --arg c "$content" \
                --argjson p "$proxied" --argjson ttl "$ttl" \
                '{type:$t, name:$n, content:$c, proxied:$p, ttl:$ttl}')
  if [[ -n "$rid" ]]; then
    cfApi PATCH "/zones/${zid}/dns_records/${rid}" "$body" >/dev/null
  else
    cfApi POST  "/zones/${zid}/dns_records"        "$body" >/dev/null
  fi
}

# cfRecordDelete <name> <type>
cfRecordDelete() {
  local name=$1 type=$2
  local zid; zid=$(cfZoneId)
  local rid; rid=$(cfRecordGet "$name" "$type")
  [[ -z "$rid" ]] && return 0
  cfApi DELETE "/zones/${zid}/dns_records/${rid}" >/dev/null
}

# cfTunnelByName <name>: stdout = tunnel id or empty
cfTunnelByName() {
  local name=$1
  local aid; aid=$(cfAccountId)
  local resp; resp=$(cfApi GET "/accounts/${aid}/cfd_tunnel?name=${name}&is_deleted=false")
  jq -r '.result[0].id // empty' <<<"$resp"
}

# cfTunnelCreate <name>: stdout = tunnel id
cfTunnelCreate() {
  local name=$1
  local existing; existing=$(cfTunnelByName "$name")
  if [[ -n "$existing" ]]; then
    printf '%s' "$existing"; return 0
  fi
  local aid; aid=$(cfAccountId)
  local secret; secret=$(openssl rand -base64 32 | tr -d '\n')
  local body
  body=$(jq -n --arg n "$name" --arg s "$secret" '{name:$n, tunnel_secret:$s, config_src:"cloudflare"}')
  local resp; resp=$(cfApi POST "/accounts/${aid}/cfd_tunnel" "$body")
  jq -r '.result.id // empty' <<<"$resp"
}

cfTunnelGet() {
  local tid=$1
  local aid; aid=$(cfAccountId)
  cfApi GET "/accounts/${aid}/cfd_tunnel/${tid}"
}

cfTunnelDelete() {
  local tid=$1
  local aid; aid=$(cfAccountId)
  cfApi DELETE "/accounts/${aid}/cfd_tunnel/${tid}?cascade=true" >/dev/null
}

cfTunnelToken() {
  local tid=$1
  local aid; aid=$(cfAccountId)
  local resp; resp=$(cfApi GET "/accounts/${aid}/cfd_tunnel/${tid}/token")
  jq -r '.result // empty' <<<"$resp"
}

# cfTunnelConfigPut <tid> <config-json>
cfTunnelConfigPut() {
  local tid=$1 cfg=$2
  local aid; aid=$(cfAccountId)
  local body; body=$(jq -n --argjson c "$cfg" '{config:$c}')
  cfApi PUT "/accounts/${aid}/cfd_tunnel/${tid}/configurations" "$body" >/dev/null
}

# cfDnsRouteUpsert <name>: write CNAME -> <tid>.cfargotunnel.com proxied=true
cfDnsRouteUpsert() {
  local name=$1
  local tid; tid=$(stateGet cf_tunnel_id)
  [[ -n "$tid" ]] || die "Cloudflare Tunnel has not been created yet"
  cfRecordUpsert "$name" CNAME "${tid}.cfargotunnel.com" true
}

# cfRadarTopDomains: output the candidate domain list(one per line)
cfRadarTopDomains() {
  local out
  out=$(cfApi GET "/radar/ranking/top?limit=100" 2>/dev/null) || true
  if [[ -n "$out" ]]; then
    jq -r '.result.top_0[]?.domain // empty' <<<"$out" 2>/dev/null && return 0 || true
  fi
  out=$(cfApi GET "/radar/datasets/ranking_top_1000" 2>/dev/null) || true
  if [[ -n "$out" ]]; then
    jq -r '.result.top_0[]?.domain // empty' <<<"$out" 2>/dev/null && return 0 || true
  fi
  return 0
}

# cfTokenPreflight: five-step preflight; die if any step fails
cfTokenPreflight() {
  banner "Cloudflare Token preflight"
  local edit_hint="https://dash.cloudflare.com/profile/api-tokens"
  local zid aid

  # 1. token self-validity
  local verify hfile
  hfile=$(__cfAuthHeaderFile) || die "CF Token preflight failed: could not prepare auth header"
  verify=$(curl -fsS --max-time 10 \
    -H "@${hfile}" \
    "${CF_API_BASE}/user/tokens/verify" 2>/dev/null || true)
  rm -f "$hfile"
  local vsucc; vsucc=$(jq -r '.success // false' <<<"$verify" 2>/dev/null || echo false)
  [[ "$vsucc" == "true" ]] || die "CF Token is invalid or has been revoked. Recreate it: $edit_hint"

  # 2. Zone:DNS:Read
  local zresp; zresp=$(cfApi GET "/zones?name=${ROOT_DOMAIN}") || die "missing Zone list permission: $edit_hint"
  zid=$(jq -r '.result[0].id // empty' <<<"$zresp")
  [[ -n "$zid" ]] || die "domain ${ROOT_DOMAIN} is outside this token's scope: $edit_hint"

  # 3. DNS record read
  cfApi GET "/zones/${zid}/dns_records?per_page=1" >/dev/null \
    || die "missing Zone:DNS:Read permission: $edit_hint"

  # 4. account list
  local aresp; aresp=$(cfApi GET "/accounts?per_page=1") || die "missing Account:Read permission: $edit_hint"
  aid=$(jq -r '.result[0].id // empty' <<<"$aresp")
  [[ -n "$aid" ]] || die "failed to get Cloudflare account ID: $edit_hint"

  # 5. tunnel list
  cfApi GET "/accounts/${aid}/cfd_tunnel?per_page=1" >/dev/null \
    || die "missing Account:Cloudflare Tunnel:Edit permission: $edit_hint"

  stateSet cf_zone_id "$zid"
  stateSet cf_account_id "$aid"
  ok "CF Token preflight passed: zone=${zid} account=${aid}"
}

# ============ SECTION 08 acme.sh orchestration ============
readonly ACME_HOME="/root/.acme.sh"
readonly ACME_BIN="${ACME_HOME}/acme.sh"

acmeInstall() {
  if [[ -x "$ACME_BIN" ]]; then
    ok "acme.sh already exists: $ACME_BIN"
    return 0
  fi
  log "Installing acme.sh"
  curl -fsSL https://get.acme.sh | sh -s "email=${ACME_EMAIL}" --nocron >/dev/null
  [[ -x "$ACME_BIN" ]] || die "acme.sh installation failed"
}

acmeIssue() {
  local root="$ROOT_DOMAIN"
  local aid; aid=$(stateGet cf_account_id)
  local ca; ca=$(stateGet acme_ca); [[ -n "$ca" ]] || ca="letsencrypt"
  log "Issuing wildcard certificate: ${root} *.${root} (CA=${ca})"
  # `local -` scopes shell options to this function; `set +x` keeps the
  # CF_Token env-prefix assignment out of any JANUS_DEBUG=1 xtrace output.
  local -
  set +x
  CF_Token="$CF_API_TOKEN" CF_Account_ID="$aid" \
    "$ACME_BIN" --issue --dns dns_cf -d "$root" -d "*.${root}" \
      --server "$ca" --ecc --force >/dev/null
}

acmeInstallCert() {
  local root="$ROOT_DOMAIN"
  mkdir -p "$CERT_DIR"; chmod 700 "$CERT_DIR"
  "$ACME_BIN" --install-cert -d "$root" --ecc \
    --key-file       "$CERT_KEY" \
    --fullchain-file "$CERT_FULLCHAIN" \
    --reloadcmd      "systemctl restart ${UNIT_XRAY} ${UNIT_SBOX} 2>/dev/null || true" >/dev/null
  chmod 600 "$CERT_KEY"
  acmeValidateCert
  ok "Certificate installed and reloadcmd bound"
}

acmeValidateCert() {
  local root="$ROOT_DOMAIN"
  [[ -s "$CERT_FULLCHAIN" ]] || die "certificate was not generated: $CERT_FULLCHAIN"
  local sans; sans=$(openssl x509 -in "$CERT_FULLCHAIN" -noout -ext subjectAltName 2>/dev/null || true)
  grep -q "DNS:${root}" <<<"$sans" || die "certificate is missing SAN: ${root}"
  grep -q "DNS:\*\\.${root}" <<<"$sans" || die "certificate is missing SAN: *.${root}"
}

moduleAcme() {
  banner "Issue Cloudflare DNS-01 wildcard certificate"
  requireEnv
  cfTokenPreflight
  cfAccountId >/dev/null
  acmeInstall
  acmeIssue
  acmeInstallCert
  # acme_ca is set by certSwitchCA; keep the default state value if not already overridden.
  [[ -n "$(stateGet acme_ca)" ]] || stateSet acme_ca "letsencrypt"
}

# ============ SECTION 09 core binary installation and upgrades ============
__download() {
  local url=$1 out=$2
  retry 3 3 curl -fsSL --max-time 60 -o "$out" "$url" \
    || die "download failed: $url"
}

installXray() {
  JANUS_INSTALL_CHANGED=0
  local arch; arch=$(hostArch)
  local tag; tag=$(githubLatestTag XTLS/Xray-core) || die "failed to get the latest Xray version"
  local cur="" ver_out=""
  if [[ -x "$XRAY_BIN" ]]; then
    ver_out=$("$XRAY_BIN" version 2>/dev/null || true)
    [[ -n "$ver_out" ]] && cur=$(printf '%s\n' "$ver_out" | awk '/^Xray/{print $2; exit}')
  fi
  if [[ "v$cur" == "$tag" ]]; then
    ok "Xray is already up to date: $tag"
    return 0
  fi
  log "Downloading Xray $tag (${arch})"
  local asset_arch
  case "$arch" in
    amd64) asset_arch="64" ;;
    arm64) asset_arch="arm64-v8a" ;;
    *) die "Xray architecture mapping is not supported yet: $arch";;
  esac
  local url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${asset_arch}.zip"
  local tmp; tmp=$(mktemp -d)
  __download "$url" "$tmp/xray.zip"
  unzip -q "$tmp/xray.zip" -d "$tmp" || { rm -rf "$tmp"; die "failed to extract Xray"; }
  chmod 0755 "$tmp/xray"
  # Run a self-test in the temporary directory first, and only replace the production binary after it passes, to avoid breaking the service with a bad package.
  "$tmp/xray" version >/dev/null || { rm -rf "$tmp"; die "Xray temporary self-test failed, not replaced $XRAY_BIN"; }
  [[ -x "$XRAY_BIN" ]] && cp -a "$XRAY_BIN" "${XRAY_BIN}.bak"
  install -m 0755 "$tmp/xray" "$XRAY_BIN"
  rm -rf "$tmp"
  JANUS_INSTALL_CHANGED=1
  ok "Xray installed: $tag"
}

singBoxCurrentVersion() {
  [[ -x "$SBOX_BIN" ]] || return 1
  "$SBOX_BIN" version 2>/dev/null | awk 'NR==1 && $1=="sing-box" && $2=="version"{print $3; exit}'
}

singBoxHasNaive() {
  [[ -x "$SBOX_BIN" ]] || return 1
  "$SBOX_BIN" version 2>/dev/null | grep -qi 'with_naive\|naive'
}

installSingBox() {
  JANUS_INSTALL_CHANGED=0
  local tag; tag=$(githubLatestTag SagerNet/sing-box) || die "failed to get the latest sing-box version"
  local cur; cur=$(singBoxCurrentVersion || true)
  if [[ -n "$cur" && "v$cur" == "$tag" ]] && singBoxHasNaive; then
    ok "sing-box is already up to date: $tag(with naive)"
    return 0
  fi
  __sbox_install_tag "$tag" || {
    warn "sing-box ${tag} installation or naive self-test failed, falling back to ${SBOX_FALLBACK_TAG_WITH_NAIVE}"
    __sbox_install_tag "$SBOX_FALLBACK_TAG_WITH_NAIVE"
  }
}

__sbox_install_tag() {
  local tag=$1 arch; arch=$(hostArch)
  local ver="${tag#v}"
  local pkg="sing-box-${ver}-linux-${arch}"
  local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${pkg}.tar.gz"
  local tmp; tmp=$(mktemp -d)
  log "Downloading sing-box ${tag}"
  __download "$url" "$tmp/sbox.tar.gz" || { rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/sbox.tar.gz" -C "$tmp" || { rm -rf "$tmp"; return 1; }
  local src="$tmp/${pkg}/sing-box"
  [[ -x "$src" ]] || { rm -rf "$tmp"; return 1; }
  # Run version + naive self-tests in the temporary directory first; only replace the production binary after the package is confirmed usable.
  # If any step fails, return 1 directly and keep the existing $SBOX_BIN intact so the caller can fall back to the fallback tag.
  "$src" version >/dev/null 2>&1 || { warn "sing-box ${tag} temporary self-test failed, not replaced $SBOX_BIN"; rm -rf "$tmp"; return 1; }
  if ! "$src" version 2>/dev/null | grep -qi 'with_naive\|naive'; then
    warn "sing-box ${tag} does not include the naive tag, not replaced $SBOX_BIN"
    rm -rf "$tmp"
    return 1
  fi
  [[ -x "$SBOX_BIN" ]] && cp -a "$SBOX_BIN" "${SBOX_BIN}.bak"
  install -m 0755 "$src" "$SBOX_BIN" || { rm -rf "$tmp"; return 1; }
  if [[ -f "$tmp/${pkg}/libcronet.so" ]]; then
    install -m 0644 "$tmp/${pkg}/libcronet.so" "$(dirname "$SBOX_BIN")/libcronet.so" || { rm -rf "$tmp"; return 1; }
  fi
  rm -rf "$tmp"
  JANUS_INSTALL_CHANGED=1
  ok "sing-box installed: $tag(with naive)"
}

installCloudflared() {
  JANUS_INSTALL_CHANGED=0
  local arch; arch=$(hostArch)
  local tag; tag=$(githubLatestTag cloudflare/cloudflared) || die "failed to get the latest cloudflared version"
  local cur=""
  [[ -x "$CFD_BIN" ]] && cur=$("$CFD_BIN" --version 2>/dev/null | awk '{print $3}')
  if [[ -n "$cur" && "$tag" == "$cur" ]]; then
    ok "cloudflared is already up to date: $cur"
    return 0
  fi
  local url="https://github.com/cloudflare/cloudflared/releases/download/${tag}/cloudflared-linux-${arch}"
  log "Downloading cloudflared ${tag}"
  local tmp; tmp=$(mktemp -d)
  __download "$url" "$tmp/cloudflared"
  chmod 0755 "$tmp/cloudflared"
  "$tmp/cloudflared" --version >/dev/null || { rm -rf "$tmp"; die "cloudflared self-test failed"; }
  [[ -x "$CFD_BIN" ]] && cp -a "$CFD_BIN" "${CFD_BIN}.bak"
  install -m 0755 "$tmp/cloudflared" "$CFD_BIN"
  rm -rf "$tmp"
  JANUS_INSTALL_CHANGED=1
  ok "cloudflared installed: $tag"
}

toolsEnsureDir() {
  install -d -m 0755 -o root -g root "$TOOLS_DIR"
}

sniEnsureScanner() {
  toolsEnsureDir
  if [[ -x "$REALITLS_BIN" ]]; then
    ok "RealiTLScanner already exists: $REALITLS_BIN"
    return 0
  fi
  local arch; arch=$(hostArch)
  local tag; tag=$(githubLatestTag XTLS/RealiTLScanner) || { warn "failed to get the RealiTLScanner version; skipping download"; return 1; }
  local asset_re
  case "$arch" in
    amd64) asset_re='linux.*(amd64|x86_64|64)' ;;
    arm64) asset_re='linux.*(arm64|aarch64)' ;;
    *) warn "RealiTLScanner has no architecture mapping yet: $arch"; return 1;;
  esac
  local url
  url=$(curl -fsSL --max-time 20 "https://api.github.com/repos/XTLS/RealiTLScanner/releases/tags/${tag}" \
    | jq -r --arg re "$asset_re" '.assets[]?.browser_download_url | select(test($re; "i"))' \
    | head -n 1)
  [[ -n "$url" ]] || { warn "RealiTLScanner not found ${tag} release asset for ${arch}"; return 1; }
  log "Attempting to download RealiTLScanner ${tag}"
  if ! curl -fsSL --max-time 60 -o "$REALITLS_BIN" "$url"; then
    rm -f "$REALITLS_BIN"
    warn "RealiTLScanner download failed; retry from menu 4.5 later if needed"
    return 1
  fi
  chmod 0755 "$REALITLS_BIN"
  ok "RealiTLScanner is ready: $REALITLS_BIN"
}

cfstEnsureBinary() {
  toolsEnsureDir
  if [[ -x "$CFST_BIN" && -s "$CFST_IP_FILE" ]]; then
    ok "CloudflareST already exists: $CFST_BIN"
    return 0
  fi
  local arch; arch=$(hostArch)
  local tarball tmp cfst_path found
  tarball="/tmp/cfst_linux_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  log "Attempting to download CloudflareSpeedTest (${arch})"
  if ! curl -fsSL --max-time 90 -o "$tarball" "https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/cfst_linux_${arch}.tar.gz"; then
    rm -rf "$tmp" "$tarball"
    warn "CloudflareSpeedTest download failed, CFST can be retried later from the menu"
    return 1
  fi
  if ! tar -zxf "$tarball" -C "$tmp" >/dev/null 2>&1; then
    rm -rf "$tmp" "$tarball"
    warn "CloudflareSpeedTest extraction failed"
    return 1
  fi
  cfst_path="$(find "$tmp" -maxdepth 3 -type f \( -name 'CloudflareST' -o -name 'cfst' \) | head -n 1)"
  if [[ -z "$cfst_path" ]]; then
    rm -rf "$tmp" "$tarball"
    warn "CloudflareSpeedTest executable not found in the package"
    return 1
  fi
  install -m 0755 -o root -g root "$cfst_path" "$CFST_BIN"
  for found in ip.txt ipv6.txt; do
    local src
    src="$(find "$tmp" -maxdepth 3 -type f -name "$found" | head -n 1)"
    [[ -n "$src" ]] && install -m 0644 -o root -g root "$src" "${TOOLS_DIR}/${found}"
  done
  rm -rf "$tmp" "$tarball"
  if [[ ! -s "$CFST_IP_FILE" ]]; then
    warn "CloudflareSpeedTest missing ip.txt candidate pool"
    return 1
  fi
  ok "CloudflareST is ready: $CFST_BIN"
}

optionalToolsPrepare() {
  toolsEnsureDir
  cfstEnsureBinary || true
  sniEnsureScanner || true
}

validIpLiteral() {
  local ip=$1
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local IFS=. a b c d
    read -r a b c d <<<"$ip"
    [[ "$a" -le 255 && "$b" -le 255 && "$c" -le 255 && "$d" -le 255 ]]
    return
  fi
  [[ "$ip" =~ ^[0-9A-Fa-f:]+$ && "$ip" == *:* ]]
}

cfstRegionValid() {
  local r
  r=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]' | tr -d ' \r\n')
  [[ -n "$r" && "$r" != "N/A" && "$r" != "NA" && "$r" != "UNKNOWN" && "$r" != "UNK" ]]
}

cfstEnabled() {
  loadState
  [[ "$(stateGet cfst_enabled)" == "true" ]]
}

cfstProbeRegion() {
  local ip=$1 out region
  out=$(curl -kfsS --max-time 8 --resolve "www.cloudflare.com:443:${ip}" \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  region=$(awk -F= '$1=="colo"{print $2; exit}' <<<"$out" | tr -d ' \r')
  cfstRegionValid "$region" && printf '%s' "$region"
}

cfstBestFromCsv() {
  local file=$1
  [[ -s "$file" ]] || return 1
  awk -F',' '
    NR==1 {
      for (i=1; i<=NF; i++) {
        h=tolower($i)
        gsub(/^[ \t\r\n"]+|[ \t\r\n"]+$/, "", h)
        if (h ~ /^(ip|ip address|ip 地址|ip地址)$/) ip=i
        if (h ~ /(download|下载速度|速度|speed)/) speed=i
        if (h ~ /(地区码|数据中心|colo|region|location)/) region=i
      }
      next
    }
    {
      cand=(ip ? $ip : $1)
      spd=(speed ? $speed : "")
      reg=(region ? $region : "")
      gsub(/^[ \t\r\n"]+|[ \t\r\n"]+$/, "", cand)
      gsub(/^[ \t\r\n"]+|[ \t\r\n"]+$/, "", spd)
      gsub(/^[ \t\r\n"]+|[ \t\r\n"]+$/, "", reg)
      n=spd
      gsub(/[^0-9.]/, "", n)
      if (cand != "" && n+0 > 0) {
        print cand, n, reg
      }
    }
  ' "$file"
}

cfstRunOnce() {
  cfstEnsureBinary || return 1
  toolsEnsureDir
  rm -f "$CFST_RESULT_FILE"
  log "Running CloudflareSpeedTest(from the VPS perspective)"
  (
    cd "$TOOLS_DIR"
    "$CFST_BIN" -n 200 -t 4 -dn 5 -dt 5 -tl 500 -o "$CFST_RESULT_FILE"
  )
}

cfstRefreshCore() {
  local mode="${1:-auto}"
  loadState || return 1
  if [[ "$mode" != "force" ]] && ! cfstEnabled; then
    log "cfst_enabled=false: skipping server-side CFST"
    return 0
  fi
  if ! cfstRunOnce; then
    stateSet alert "cfst_run_failed"
    warn "CFST run failed; keeping the previous preferred IP"
    return 0
  fi
  local best ip speed region probed cand_ip cand_speed cand_region
  best=$(cfstBestFromCsv "$CFST_RESULT_FILE" || true)
  while IFS=' ' read -r cand_ip cand_speed cand_region; do
    [[ -n "${cand_ip:-}" ]] || continue
    validIpLiteral "$cand_ip" || continue
    awk -v s="$cand_speed" 'BEGIN{exit !(s+0>0)}' || continue
    if [[ -z "${cand_region:-}" ]]; then
      probed=$(cfstProbeRegion "$cand_ip" || true)
      cand_region="$probed"
    fi
    cfstRegionValid "$cand_region" || continue
    ip="$cand_ip"; speed="$cand_speed"; region="$cand_region"
    break
  done <<<"$best"
  if [[ -z "${ip:-}" ]]; then
    stateSet alert "cfst_no_valid_result"
    warn "CFST no valid result in this run: keeping the previous IP, not switching the latest subscription"
    return 0
  fi
  local patch
  patch=$(jq -n --arg ip "$ip" --arg region "$region" --arg speed "$speed" \
    '{cfst_best_ip:$ip, cfst_best_region:$region, cfst_best_speed:$speed, cfst_updated_at:(now|todate), alert:null}')
  stateMerge "$patch"
  ok "CFST preferred IP=${ip} region=${region} speed=${speed}"
  subRegenAllCore || warn "CFST state was updated, but subscription regeneration failed"
}

cfstRefreshMenu() {
  banner "CloudflareSpeedTest preferred IP"
  loadState || return 1
  if ! cfstEnabled; then
    warn "cfst_enabled=false: enable CFST before writing speed-test results from the menu"
    log "you can toggle CFST in this menu, or run: janus cfst on"
    return 0
  fi
  cfstRefreshCore force
}

cfstStatus() {
  banner "CFST status"
  loadState
  local en; en=$(stateGet cfst_enabled); en="${en:-false}"
  printf 'enabled   : %s\n' "$en"
  printf 'best_ip   : %s\n' "$(stateGet cfst_best_ip)"
  printf 'region    : %s\n' "$(stateGet cfst_best_region)"
  printf 'speed     : %s MB/s\n' "$(stateGet cfst_best_speed)"
  printf 'updated_at: %s\n' "$(stateGet cfst_updated_at)"
  printf 'alert     : %s\n' "$(stateGet alert)"
  [[ -x "$CFST_BIN" ]] && printf 'binary    : %s\n' "$CFST_BIN" || printf 'binary    : not downloaded\n'
}

cfstToggle() {
  loadState
  local cur nv
  cur=$(stateGet cfst_enabled)
  if [[ "${1:-}" == "on" ]]; then
    nv=true
  elif [[ "${1:-}" == "off" ]]; then
    nv=false
  else
    [[ "$cur" == "true" ]] && nv=false || nv=true
  fi
  stateSetJson cfst_enabled "$nv"
  ok "cfst_enabled=$nv"
  cfstTimerApply
  # Subscriptions written to disk are pre-rendered, state so they must be regenerated after state changes, otherwise clients may still receive the CFST IP after it is disabled.
  if [[ "$cur" != "$nv" ]]; then
    subRegenAllCore || warn "subscription regeneration failed: latest may still reflect the previous CFST selection"
  fi
}

cfstClear() {
  loadState
  stateMerge '{"cfst_best_ip":"","cfst_best_region":"","cfst_best_speed":"","cfst_updated_at":"","alert":null}'
  subRegenAllCore || true
  ok "Cleared the CFST preferred IP, C-* will fall back to cdn.<root>"
}

upgradeXray()  { installXray;        [[ "${JANUS_INSTALL_CHANGED:-0}" == "1" ]] && systemctl restart "$UNIT_XRAY" 2>/dev/null || true; }
upgradeSbox()  { installSingBox;     [[ "${JANUS_INSTALL_CHANGED:-0}" == "1" ]] && systemctl restart "$UNIT_SBOX" 2>/dev/null || true; }
upgradeCFD()   { installCloudflared; [[ "${JANUS_INSTALL_CHANGED:-0}" == "1" ]] && systemctl restart "$UNIT_CFD" 2>/dev/null || true; }

verNorm() {
  local v="${1#v}"
  printf '%s\n' "$v"
}

versionGe() {
  local a b top
  a=$(verNorm "$1"); b=$(verNorm "$2")
  [[ -n "$a" && -n "$b" ]] || return 1
  top=$(printf '%s\n%s\n' "$b" "$a" | sort -V | tail -n 1)
  [[ "$top" == "$a" ]]
}

acmeCurrentVersion() {
  [[ -x "$ACME_BIN" ]] || return 1
  "$ACME_BIN" --version 2>/dev/null | awk '/^v?[0-9]+(\.[0-9]+)+/{print $1; exit}'
}

acmeLatestVersion() {
  # Use GitHub releases/latest as the single source of truth, consistent with Xray and sing-box.
  # Older acme.sh tags use a v prefix, while 3.x+ tags may not; verNorm strips it consistently.
  local out
  out=$(retry 2 2 curl -fsSL --max-time 15 https://api.github.com/repos/acmesh-official/acme.sh/releases/latest 2>/dev/null || true)
  jq -r '.tag_name // empty' <<<"$out" 2>/dev/null
}

upgradeAcme() {
  [[ -x "$ACME_BIN" ]] || { acmeInstall; return 0; }
  local cur latest after
  cur=$(acmeCurrentVersion || true)
  latest=$(acmeLatestVersion || true)
  [[ -n "$cur" ]] || cur="unknown"
  [[ -n "$latest" ]] || latest="unknown"
  # When latest is known, compare versions: if the local version is >= GitHub latest, treat it as current.
  # Avoid printing duplicate version lines.
  if [[ "$cur" != "unknown" && "$latest" != "unknown" ]] && versionGe "$cur" "$latest"; then
    ok "acme.sh is already up to date(${cur})"
    return 0
  fi
  log "acme.sh ${cur} -> ${latest}"
  "$ACME_BIN" --upgrade --auto-upgrade 0 >/dev/null || { warn "acme.sh upgrade failed"; return 1; }
  after=$(acmeCurrentVersion || true)
  ok "acme.sh upgraded: ${cur} -> ${after:-unknown}"
}

upgradeSelf() {
  banner "Upgrade install.sh"
  local tmp; tmp=$(mktemp)
  curl -fsSL --max-time 30 -o "$tmp" "$INSTALL_SH_URL" || die "failed to download install.sh"
  [[ -s "$tmp" ]] || die "downloaded content is empty"
  head -n1 "$tmp" | grep -q '^#!.*bash' || die "downloaded content is not a bash script"
  mkdir -p "$WORKDIR"
  install -m 0755 "$tmp" "$INSTALL_SH_DEST"
  rm -f "$tmp"
  ok "install.sh has been replaced with the latest version: $INSTALL_SH_DEST"
  log "run again 'janus menu' to load the new version"
}

# ============ SECTION 10 Reality SNI probing and rotation ============
# curated embedded SNI dictionary
# selection criteria: TLS1.3 + h2 + stable major sites + global anycast; 
# X25519MLKEM768/ML-DSA/cert_chain_bytes used only as positive scoring signals, not as hard filters.
sniDictBuiltin() {
  cat <<'EOF'
www.cisco.com
www.tesla.com
www.microsoft.com
www.amazon.com
aws.amazon.com
www.docker.com
www.python.org
www.djangoproject.com
www.kernel.org
www.spotify.com
www.dropbox.com
www.slack.com
www.zendesk.com
www.cnn.com
www.bbc.com
www.bing.com
www.yahoo.com
www.duckduckgo.com
addons.mozilla.org
update.googleapis.com
api.github.com
github.com
www.npmjs.com
www.nginx.com
www.fastly.com
www.linode.com
www.digitalocean.com
www.akamai.com
www.t-mobile.com
www.verizon.com
www.salesforce.com
www.shopify.com
www.zoom.us
EOF
}

sniFromCfRadar() {
  cfRadarTopDomains 2>/dev/null | head -n 100 \
    | grep -Ev '^(cloudflare\.com|.*\.cloudflare\.com|cloudflare-dns\.com)$' \
    || true
}

sniFromTranco() {
  local tmp
  tmp=$(mktemp -d)
  if curl -fsSL --max-time 45 -o "$tmp/tranco.zip" "https://tranco-list.eu/top-1m.csv.zip" 2>/dev/null \
    && unzip -p "$tmp/tranco.zip" 2>/dev/null | awk -F',' 'NR<=300 {print $2}'; then
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  return 0
}

sniNormalizeList() {
  local root="${ROOT_DOMAIN:-}"
  local sub_r="${SUB_R}.${root}" sub_cdn="${SUB_CDN}.${root}" sub_sub="${SUB_SUB}.${root}"
  awk -v r="$root" -v r1="$sub_r" -v r2="$sub_cdn" -v r3="$sub_sub" '
    {
      line=tolower($0)
      sub(/#.*/, "", line)
      gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", line)
      if (line == "") next
      if (line !~ /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/) next
      if (line == r || line == r1 || line == r2 || line == r3) next
      if (line == "cloudflare.com" || line ~ /(^|\.)cloudflare\.com$/ || line == "cloudflare-dns.com") next
      if (line == "apple.com" || line ~ /(^|\.)apple\.com$/ || line == "icloud.com" || line ~ /(^|\.)icloud\.com$/) next
      if (line == "www.cloudflare-cn.com" || line == "www.lovense.com" || line == "www.akamaihd.net") next
      if (!seen[line]++) print line
    }'
}

sniReadExtra() {
  [[ -r "$SNI_EXTRA_FILE" ]] && sniNormalizeList < "$SNI_EXTRA_FILE" || true
}

sniBuildCandidates() {
  local ranking
  ranking=$(sniFromCfRadar | sniNormalizeList | head -n 120 || true)
  if [[ -z "$ranking" ]]; then
    ranking=$(sniFromTranco | sniNormalizeList | head -n 120 || true)
  fi
  {
    sniDictBuiltin | sniNormalizeList | awk '{print "A "$0}'
    printf '%s\n' "$ranking" | awk 'NF{print "B "$0}'
    sniReadExtra | awk '{print "D "$0}'
  } | awk '!seen[$2]++{print; if (++n >= 300) exit}'
}

sniScannerExtractDomains() {
  # RealiTLScanner -out writes CSV. Current columns are IP, ORIGIN, CERT_DOMAIN, CERT_ISSUER, GEO_CODE,
  # but column order has changed across versions. Locate ORIGIN and CERT_DOMAIN by header name; fall back to
  # columns 2 and 3. awk must split each row by comma; otherwise IP and domain can be concatenated and still pass validation.
  awk -F',' '
    NR == 1 {
      o = 0; c = 0
      for (i = 1; i <= NF; i++) {
        h = tolower($i); gsub(/[[:space:]]/, "", h)
        if (h == "origin") o = i
        else if (h == "cert_domain" || h == "certdomain") c = i
      }
      if (o == 0 && c == 0) { o = 2; c = 3 }   # fallback when the header is not recognized
      if ($1 == "IP" || $1 == "ip") next       # skip the header row
    }
    {
      for (idx_i = 1; idx_i <= 2; idx_i++) {
        col = (idx_i == 1 ? o : c)
        if (col == 0 || col > NF) continue
        token = tolower($col)
        gsub(/[[:space:]"'\''`<>{}\[\]();:]/, "", token)
        if (token ~ /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/) print token
      }
    }' | sniNormalizeList
}

sniScannerRunFile() {
  local in_file=$1 out_file=$2
  local bin="$REALITLS_BIN"
  [[ -x "$bin" ]] || return 1
  if have timeout; then
    timeout 180 "$bin" -in "$in_file" -out "$out_file"
  else
    "$bin" -in "$in_file" -out "$out_file"
  fi
}

# sniVerifyCandidatesWithScanner: stdin "<src> <host>"; stdout "<src> <host>"
sniVerifyCandidatesWithScanner() {
  local tmp cand_file domain_file out_file verified_file mapped_file
  tmp=$(mktemp -d)
  cand_file="$tmp/candidates.map"
  domain_file="$tmp/candidates.txt"
  out_file="$tmp/scan.csv"
  verified_file="$tmp/verified.txt"
  mapped_file="$tmp/mapped.txt"

  awk 'NF>=2 {print $1, tolower($2)}' > "$cand_file"
  awk '{print $2}' "$cand_file" > "$domain_file"
  if [[ ! -s "$domain_file" ]]; then
    rm -rf "$tmp"
    return 0
  fi

  if ! sniEnsureScanner >/dev/null 2>&1 || ! sniScannerRunFile "$domain_file" "$out_file" >/dev/null 2>&1; then
    warn "RealiTLScanner candidate validation is unavailable; falling back to local openssl probing for this run"
    cat "$cand_file"
    rm -rf "$tmp"
    return 0
  fi

  if [[ -s "$out_file" ]]; then
    sniScannerExtractDomains < "$out_file" | awk '!seen[$0]++' > "$verified_file"
  fi
  if [[ ! -s "$verified_file" ]]; then
    warn "RealiTLScanner returned no usable candidates; falling back to local openssl probing for this run"
    cat "$cand_file"
    rm -rf "$tmp"
    return 0
  fi

  awk 'NR==FNR{src[$2]=$1; next} ($1 in src){print src[$1], $1}' "$cand_file" "$verified_file" > "$mapped_file"
  if [[ ! -s "$mapped_file" ]]; then
    warn "RealiTLScanner results did not match the original candidates; falling back to local openssl probing for this run"
    cat "$cand_file"
    rm -rf "$tmp"
    return 0
  fi
  cat "$mapped_file"
  rm -rf "$tmp"
}

# sniLocalProbe: stdin "<src> <host>" rows; stdout "<src> <host> <rtt_ms> <cert_bytes>"
# only output candidates that pass hard filters
sniLocalProbe() {
  local jobs=8
  __sni_probe_one() {
    local line=$1
    local src host rtt cert
    src=$(awk '{print $1}' <<<"$line")
    host=$(awk '{print $2}' <<<"$line")
    [[ -z "$host" ]] && return 0
    local start end
    start=$(date +%s%3N)
    local out
    out=$(timeout 6 openssl s_client -connect "${host}:443" -servername "$host" \
            -verify_hostname "$host" -alpn h2 -tls1_3 </dev/null 2>&1 | tr -d '\000' || true)
    end=$(date +%s%3N)
    rtt=$((end-start))
    grep -Eq "New, TLSv1\.3|Protocol version: TLSv1\.3|Protocol: TLSv1\.3" <<<"$out" || return 0
    grep -q "ALPN protocol: h2" <<<"$out" || return 0
    grep -q "Verify return code: 0" <<<"$out" || return 0
    # extract certificate-chain/handshake output byte count(rough)
    cert=$(wc -c <<<"$out")
    printf '%s %s %s %s\n' "$src" "$host" "$rtt" "$cert"
  }
  export -f __sni_probe_one
  xargs -P "$jobs" -I{} bash -c '__sni_probe_one "$@"' _ "{}"
}

# sniHistoryRate <host>: stdout 0-1
sniHistoryRate() {
  local host=$1
  jq -r --arg h "$host" '.sni_history[$h].success // 0.7' "$STATE_FILE" 2>/dev/null
}

sniHistoryUpdate() {
  local host=$1 result=$2
  [[ -n "$host" ]] || return 0
  local ok=false
  [[ "$result" == "success" ]] && ok=true
  __state_lock_run jq --arg h "$host" --argjson ok "$ok" '
    .sni_history //= {} |
    (.sni_history[$h] // {success:0.7, ok:0, fail:0}) as $old |
    .sni_history[$h] = {
      success: (if $ok then (($old.success // 0.7) * 0.7 + 0.3) else (($old.success // 0.7) * 0.7) end),
      ok: (($old.ok // 0) + (if $ok then 1 else 0 end)),
      fail: (($old.fail // 0) + (if $ok then 0 else 1 end)),
      updated_at: (now|todate)
    } | .updated_at=(now|todate)' "$STATE_FILE"
}

# sniScore: stdin "<src> <host> <rtt_ms> <cert_bytes>"; stdout "<score> <host> ..."
sniScore() {
  local src host rtt cert hist
  # Use explicit IFS=' ': the script-level IFS=$'\n\t' would make read put the whole row into $src.
  while IFS=' ' read -r src host rtt cert _; do
    [[ -n "${src:-}" && -n "${host:-}" ]] || continue
    hist=$(sniHistoryRate "$host")
    awk -v src="$src" -v host="$host" -v rtt="$rtt" -v cert="$cert" -v hist="$hist" '
      BEGIN {
        rtt_score = (rtt>0) ? (200.0/(rtt+50)) : 0;
        cert_norm = (cert>4000) ? 1.0 : (cert/4000.0);
        src_w = (src=="D") ? 1.2 : (src=="A" ? 1.0 : (src=="B" ? 0.9 : 0.8));
        score = rtt_score*0.4 + cert_norm*0.3 + src_w*0.2 + hist*0.1;
        printf "%.4f %s %s %d %d %.3f\n", score, host, src, rtt, cert, hist;
      }'
  done | sort -rn
}

# sniApply: <candidate>; write state after grace validation; return non-zero on failure
sniApply() {
  local cand=$1
  local privkey pubkey shortid uuid
  privkey=$(stateGet reality_privkey); pubkey=$(stateGet reality_pubkey)
  shortid=$(stateGet reality_shortid); uuid=$(stateGet uuid)
  [[ -n "$privkey" && -n "$pubkey" && -n "$shortid" && -n "$uuid" ]] || die "Reality keys/UUID are missing"

  local old_sni; old_sni=$(stateGet reality_sni)
  local server_names
  if [[ -n "$old_sni" && "$old_sni" != "$cand" ]]; then
    server_names=$(jq -n --arg a "$cand" --arg b "$old_sni" '[$a,$b]')
  else
    server_names=$(jq -n --arg a "$cand" '[$a]')
  fi

  local test_cfg=/tmp/janus-reality-test.json
  jq -n --arg uuid "$uuid" --arg sni "$cand" --arg priv "$privkey" \
        --arg sid "$shortid" --argjson names "$server_names" '
    {log:{loglevel:"warning"},
     inbounds:[{
       port:1080, protocol:"vless",
       settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:"none"},
       streamSettings:{network:"tcp", security:"reality",
         realitySettings:{
           target:($sni+":443"), serverNames:$names,
           privateKey:$priv, shortIds:[$sid]}}}],
     outbounds:[{protocol:"freedom"}]}' > "$test_cfg"

  if ! "$XRAY_BIN" run -test -c "$test_cfg" >/dev/null 2>&1; then
    rm -f "$test_cfg"
    sniHistoryUpdate "$cand" fail || true
    return 1
  fi
  rm -f "$test_cfg"

  stateSet reality_sni "$cand"
  # Keep the previous SNI as the old backup during the grace period.
  # Only write $cand itself as last_known_good when there is no previous record or when old and new are identical.
  if [[ -n "$old_sni" && "$old_sni" != "$cand" ]]; then
    stateSet last_known_good_sni "$old_sni"
  elif [[ -z "$(stateGet last_known_good_sni)" ]]; then
    stateSet last_known_good_sni "$cand"
  fi
  stateSetJson sni_grace_server_names "$server_names"
  sniHistoryUpdate "$cand" success || true
  return 0
}

sniPickBest() {
  banner "Reality SNI candidate probing"
  loadState

  # override priority 1: environment variables
  if [[ -n "${JANUS_SNI_OVERRIDE:-}" ]]; then
    log "Using environment variable JANUS_SNI_OVERRIDE=${JANUS_SNI_OVERRIDE}"
    if [[ "${JANUS_SNI_DRY_RUN:-0}" == "1" ]]; then
      log "DRY_RUN: skip grace validation"
      return 0
    fi
    sniApply "$JANUS_SNI_OVERRIDE" || die "JANUS_SNI_OVERRIDE grace validation failed"
    return 0
  fi

  # override priority 2: state.sni_override
  local ov; ov=$(stateGet sni_override)
  if [[ -n "$ov" && "$ov" != "null" ]]; then
    log "Using state.sni_override=${ov}"
    if [[ "${JANUS_SNI_DRY_RUN:-0}" == "1" || "$(stateGet sni_dry_run)" == "true" ]]; then
      log "DRY_RUN: skip grace validation"
      return 0
    fi
    sniApply "$ov" || die "sni_override grace validation failed"
    return 0
  fi

  log "Building candidate pool..."
  local cands; cands=$(sniBuildCandidates)
  local n; n=$(wc -l <<<"$cands")
  log "candidate count: $n"

  log "RealiTLScanner candidate-file validation..."
  local verified; verified=$(printf '%s\n' "$cands" | sniVerifyCandidatesWithScanner | awk 'NF >= 2')
  local vn; vn=$(wc -l <<<"$verified")
  log "candidate count after validation: $vn"

  log "local concurrent openssl probing..."
  local probed; probed=$(printf '%s\n' "$verified" | sniLocalProbe | awk 'NF >= 4')
  local scored; scored=$(printf '%s\n' "$probed" | sniScore)

  if [[ -z "$scored" ]]; then
    local current; current=$(stateGet reality_sni)
    warn "no candidates passed the filters; trying to keep the previous SNI=${current}"
    stateSet alert "sni_no_candidate"
    if [[ -n "$current" && "$current" != "null" ]] && sniApply "$current"; then
      warn "continuing to use the current SNI=${current}"
      return 0
    fi
    return 1
  fi
  printf '%s\n' "$scored" | head -n 10
  if [[ "${JANUS_SNI_DRY_RUN:-0}" == "1" || "$(stateGet sni_dry_run)" == "true" ]]; then
    log "DRY_RUN: print scores only; do not apply"
    return 0
  fi
  local top; top=$(awk '{print $2; exit}' <<<"$scored")
  local top_line; top_line=$(awk 'NR==1{print; exit}' <<<"$scored")
  local backups; backups=$(awk 'NR>1 && NR<=6 {print $2}' <<<"$scored")
  if sniApply "$top"; then
    stateSet sni_last_score_summary "$top_line"
    awk 'NR==1{printf "selected summary: score=%s domain=%s src=%s rtt=%sms cert=%sB history=%s\nformula: score=(inverse RTTx0.4)+(normalized certificate-chain lengthx0.3)+(source weightx0.2)+(historical success ratex0.1)\n",$1,$2,$3,$4,$5,$6}' <<<"$top_line"
    ok "Applied SNI=$top"
    stateSetJson alert 'null'
    return 0
  fi
  local b
  for b in $backups; do
    if sniApply "$b"; then
      local b_line; b_line=$(awk -v h="$b" '$2==h{print; exit}' <<<"$scored")
      stateSet sni_last_score_summary "$b_line"
      awk 'NR==1{printf "selected summary: score=%s domain=%s src=%s rtt=%sms cert=%sB history=%s\nformula: score=(inverse RTTx0.4)+(normalized certificate-chain lengthx0.3)+(source weightx0.2)+(historical success ratex0.1)\n",$1,$2,$3,$4,$5,$6}' <<<"$b_line"
      ok "fell back to backup SNI=$b"
      return 0
    fi
  done
  stateSet alert "sni_all_failed"
  warn "all candidates failed grace validation; keeping the previous SNI"
  return 1
}

sniCheckNow() {
  loadState
  local auto; auto=$(stateGet sni_auto_rotate)
  if [[ "$auto" == "true" ]]; then
    sniPickBest && sniApplyTriggerRestart || true
  else
    log "auto_rotate=false: check and warn only"
    JANUS_SNI_DRY_RUN=1 sniPickBest || true
  fi
}

sniApplyTriggerRestart() {
  # SNI is referenced by both Xray Reality and sing-box ShadowTLS handshake.server.
  # Both sides must be regenerated and restarted together; otherwise the ShadowTLS handshake SNI and the
  # plugin-opts.host value written to subscriptions will diverge and fail with EOF/timeout in strict_mode.
  xrayConfigAssemble
  sboxConfigAssemble
  if systemctl list-unit-files "$UNIT_XRAY" --no-legend 2>/dev/null | grep -q "$UNIT_XRAY"; then
    systemctl restart "$UNIT_XRAY" 2>/dev/null || true
  fi
  if systemctl list-unit-files "$UNIT_SBOX" --no-legend 2>/dev/null | grep -q "$UNIT_SBOX"; then
    systemctl restart "$UNIT_SBOX" 2>/dev/null || true
  fi
  subRegenAllCore || true
}

sniRotateNow() {
  banner "rotate immediately Reality SNI(menu 4.1)"
  if sniPickBest; then
    sniApplyTriggerRestart
  else
    warn "rotation did not complete"
    return 1
  fi
}

sniStatus() {
  banner "Reality SNI status"
  loadState
  printf 'Current SNI       : %s\n' "$(stateGet reality_sni)"
  printf 'last_known_good: %s\n' "$(stateGet last_known_good_sni)"
  printf 'override       : %s\n' "$(stateGet sni_override)"
  printf 'auto_rotate    : %s\n' "$(stateGet sni_auto_rotate)"
  printf 'dry_run        : %s\n' "$(stateGet sni_dry_run)"
  printf 'mldsa65_enabled: %s\n' "$(stateGet reality_mldsa65_enabled)"
  printf 'score_summary  : %s\n' "$(stateGet sni_last_score_summary)"
  printf 'alert          : %s\n' "$(stateGet alert)"
}

sniSetOverride() {
  local v; prompt v "Enter the SNI domain to lock"
  [[ -n "$v" ]] || { warn "No SNI entered; canceled"; return 0; }
  local old_ov; old_ov=$(stateGet sni_override)
  stateSet sni_override "$v"
  if ! sniApply "$v"; then
    # Roll back override so the next sniPickBest does not lock onto the same invalid domain.
    if [[ -n "$old_ov" && "$old_ov" != "null" ]]; then
      stateSet sni_override "$old_ov"
    else
      stateSetJson sni_override 'null'
    fi
    err "$v grace check failed; override was not applied"
    return 1
  fi
  sniApplyTriggerRestart
  ok "Set sni_override=$v and applied it to reality_sni"
}

sniClearOverride() {
  local old_ov; old_ov=$(stateGet sni_override)
  if [[ -z "$old_ov" || "$old_ov" == "null" ]]; then
    ok "sni_override is already null; nothing to clear"
    return 0
  fi
  stateSetJson sni_override 'null'
  local current fallback
  current=$(stateGet reality_sni)
  fallback=$(stateGet last_known_good_sni)
  if [[ -n "$fallback" && "$fallback" != "null" && "$fallback" != "$old_ov" ]]; then
    if sniApply "$fallback"; then
      sniApplyTriggerRestart
      ok "Cleared sni_override and restored last_known_good_sni=$fallback"
      return 0
    fi
    warn "Cleared sni_override, but last_known_good_sni=$fallback grace check failed; current reality_sni remains ${current:-unknown}"
    warn "to reselect immediately, use menu 4.1 to rotate SNI now"
    return 1
  fi
  if [[ -n "$current" && "$current" != "null" && "$current" != "$old_ov" ]]; then
    sniApplyTriggerRestart
    ok "Cleared sni_override; current reality_sni=$current"
  else
    ok "Cleared sni_override; current reality_sni remains ${current:-unknown}"
    log "to reselect immediately, use menu 4.1 to rotate SNI now"
  fi
}

sniShowDict() {
  banner "Reality SNI curated dictionary"
  sniDictBuiltin
}

sniScannerExtend() {
  banner "RealiTLScanner candidate validation"
  sniEnsureScanner || die "RealiTLScanner is unavailable"
  local tmp cand_file out_file result_file
  tmp=$(mktemp -d)
  cand_file="$tmp/candidates.txt"
  out_file="$tmp/scan.csv"
  result_file="$tmp/verified.txt"
  sniBuildCandidates | awk '{print $2}' > "$cand_file"
  local n; n=$(wc -l < "$cand_file")
  log "candidate file: $cand_file(${n} domains)"
  if sniScannerRunFile "$cand_file" "$out_file"; then
    sniScannerExtractDomains < "$out_file" | awk '!seen[$0]++' > "$result_file" || true
    local vn; vn=$(wc -l < "$result_file" 2>/dev/null || echo 0)
    log "validated candidate count: $vn"
    [[ -s "$result_file" ]] && head -n 30 "$result_file"
    if [[ -s "$result_file" ]]; then
      local prev_lines=0 final_lines=0 added=0 existing_norm new_norm merge
      install -d -m 755 "$(dirname "$SNI_EXTRA_FILE")"
      existing_norm="$tmp/existing-normalized.txt"
      new_norm="$tmp/new-normalized.txt"
      merge="$tmp/sni-extra-merged.txt"
      if [[ -f "$SNI_EXTRA_FILE" ]]; then
        sniNormalizeList < "$SNI_EXTRA_FILE" | awk '!seen[$0]++' > "$existing_norm"
      else
        : > "$existing_norm"
      fi
      sniNormalizeList < "$result_file" | awk '!seen[$0]++' > "$new_norm"
      prev_lines=$(wc -l < "$existing_norm" 2>/dev/null || echo 0)
      awk 'NR==FNR{seen[$0]=1; next} !seen[$0]++{print}' "$existing_norm" "$new_norm" > "$tmp/sni-extra-added.txt"
      added=$(wc -l < "$tmp/sni-extra-added.txt" 2>/dev/null || echo 0)
      cat "$existing_norm" "$tmp/sni-extra-added.txt" > "$merge"
      install -m 644 "$merge" "$SNI_EXTRA_FILE"
      final_lines=$(wc -l < "$SNI_EXTRA_FILE" 2>/dev/null || echo 0)
      ok "Candidate validation completed; appended ${added} new domains to ${SNI_EXTRA_FILE} automatically (${final_lines} total)."
    else
      warn "no valid candidates parsed, not written to ${SNI_EXTRA_FILE}"
    fi
  else
    warn "RealiTLScanner candidate validation failed"
  fi
  rm -rf "$tmp"
}

advRealiTLScannerAddr() {
  banner "RealiTLScanner raw scan(danger)"
  warn "This entry actively scans the specified IP/CIDR/domain from the VPS. It may violate the provider AUP and may cause the VPS to be flagged, throttled, or suspended."
  confirm "I understand the risk and confirm that I will scan only targets I am authorized to test" || return 0
  confirm "Confirm again: continue the RealiTLScanner raw scan" || return 0
  sniEnsureScanner || die "RealiTLScanner is unavailable"
  local target out
  prompt target "Target IP/CIDR/domain or local file path" ""
  [[ -n "$target" ]] || return 0
  out="${TOOLS_DIR}/realitls-addr-$(date +%Y%m%d%H%M%S).csv"
  if [[ -f "$target" ]]; then
    log "Local file detected; using -in: $target"
    sniScannerRunFile "$target" "$out" || warn "RealiTLScanner -in execution failed"
  else
    log "Using -addr: $target"
    "$REALITLS_BIN" -addr "$target" -out "$out" || warn "RealiTLScanner -addr execution failed"
  fi
  if [[ -s "$out" ]]; then
    ok "raw scan output: $out"
    sniScannerExtractDomains < "$out" | awk '!seen[$0]++' | head -n 50 || true
    log "will not be written automatically to ${SNI_EXTRA_FILE}; manually review and paste entries when expanding the candidate pool."
  else
    warn "no valid output was generated: $out"
  fi
}

realityRekey() {
  banner "Reset Reality key pair"
  loadState
  local out priv pub
  out=$("$XRAY_BIN" x25519 2>/dev/null) || die "xray x25519 execution failed"
  priv=$(awk -F': ' '/Private/{print $2}' <<<"$out")
  pub=$(awk  -F': ' '/Public/{print $2}'  <<<"$out")
  [[ -n "$priv" && -n "$pub" ]] || die "x25519 output parsing failed"
  stateSet reality_privkey "$priv"
  stateSet reality_pubkey  "$pub"
  ok "New Reality key pair written to state"
}

realityReshortid() {
  banner "Reset Reality short_id"
  local sid; sid=$(openssl rand -hex 8)
  stateSet reality_shortid "$sid"
  ok "New short_id=$sid"
}

realityResetCredentials() {
  banner "Reset Reality keys/credentials"
  confirm "Confirm reset of the Reality key pair and short_id?clients need to refresh subscriptions" || return 0
  realityRekey
  realityReshortid
  xrayConfigAssemble
  systemctl restart "$UNIT_XRAY" 2>/dev/null || true
  subRegenAllCore || true
  ok "Reality keys/credentials reset"
  subShow
}

realityToggleMldsa() {
  loadState
  local enabled; enabled=$(stateGet reality_mldsa65_enabled)
  log "Current ML-DSA-65: ${enabled:-false}"
  local v; prompt v "Enter on to enable, off to disable" "$([[ "$enabled" == "true" ]] && echo off || echo on)"
  case "${v,,}" in
    on|enable|enabled|true|1)
      local seed verify out
      out=$("$XRAY_BIN" mldsa65 2>/dev/null) || die "the current Xray does not support mldsa65 generation"
      seed=$(awk -F': ' '/^Seed:/{print $2; exit}' <<<"$out")
      verify=$(awk -F': ' '/^Verify:/{print $2; exit}' <<<"$out")
      [[ -n "$seed" && -n "$verify" ]] || die "mldsa65 generation output is unrecognized"
      stateSet reality_mldsa65_seed "$seed"
      stateSet reality_mldsa65_verify "$verify"
      stateSet reality_mldsa65_enabled "true"
      ;;
    off|disable|disabled|false|0)
      stateSet reality_mldsa65_enabled "false"
      ;;
    *) die "Enter on or off";;
  esac
  xrayConfigAssemble
  systemctl restart "$UNIT_XRAY" 2>/dev/null || true
  subRegenAllCore || true
  ok "ML-DSA-65 updated"
}

# ============ SECTION 11 protocol metadata arrays ============
PROTO_TAGS=(
  R-VLESS-Vision
  R-VLESS-XHTTP
  R-VLESS-gRPC
  C-VLESS-XHTTP
  C-VLESS-WS
  C-Trojan-WS
  C-VMess-WS
  C-VLESS-HTTPUpgrade
  U-Hysteria2
  U-TUIC-v5
  D-AnyTLS
  D-NaiveProxy
  D-ShadowTLS-SS
)

declare -A PROTO_CORE PROTO_PORT PROTO_CDN PROTO_HOP PROTO_SCHEME

# core
PROTO_CORE[R-VLESS-Vision]=xray
PROTO_CORE[R-VLESS-XHTTP]=xray
PROTO_CORE[R-VLESS-gRPC]=xray
PROTO_CORE[C-VLESS-XHTTP]=xray
PROTO_CORE[C-VLESS-WS]=xray
PROTO_CORE[C-Trojan-WS]=xray
PROTO_CORE[C-VMess-WS]=xray
PROTO_CORE[C-VLESS-HTTPUpgrade]=xray
PROTO_CORE[U-Hysteria2]=sbox
PROTO_CORE[U-TUIC-v5]=sbox
PROTO_CORE[D-AnyTLS]=sbox
PROTO_CORE[D-NaiveProxy]=sbox
PROTO_CORE[D-ShadowTLS-SS]=sbox

# port
PROTO_PORT[R-VLESS-Vision]=443
PROTO_PORT[R-VLESS-XHTTP]=8443
PROTO_PORT[R-VLESS-gRPC]=2053
PROTO_PORT[C-VLESS-XHTTP]=31000
PROTO_PORT[C-VLESS-WS]=31001
PROTO_PORT[C-Trojan-WS]=31002
PROTO_PORT[C-VMess-WS]=31003
PROTO_PORT[C-VLESS-HTTPUpgrade]=31004
PROTO_PORT[U-Hysteria2]=4433
PROTO_PORT[U-TUIC-v5]=11443
PROTO_PORT[D-AnyTLS]=8444
PROTO_PORT[D-NaiveProxy]=10443
PROTO_PORT[D-ShadowTLS-SS]=9443

# cdn (1=via Cloudflared, 0=direct)
PROTO_CDN[R-VLESS-Vision]=0
PROTO_CDN[R-VLESS-XHTTP]=0
PROTO_CDN[R-VLESS-gRPC]=0
PROTO_CDN[C-VLESS-XHTTP]=1
PROTO_CDN[C-VLESS-WS]=1
PROTO_CDN[C-Trojan-WS]=1
PROTO_CDN[C-VMess-WS]=1
PROTO_CDN[C-VLESS-HTTPUpgrade]=1
PROTO_CDN[U-Hysteria2]=0
PROTO_CDN[U-TUIC-v5]=0
PROTO_CDN[D-AnyTLS]=0
PROTO_CDN[D-NaiveProxy]=0
PROTO_CDN[D-ShadowTLS-SS]=0

# hop (start:end)
PROTO_HOP[R-VLESS-Vision]=""
PROTO_HOP[R-VLESS-XHTTP]=""
PROTO_HOP[R-VLESS-gRPC]=""
PROTO_HOP[C-VLESS-XHTTP]=""
PROTO_HOP[C-VLESS-WS]=""
PROTO_HOP[C-Trojan-WS]=""
PROTO_HOP[C-VMess-WS]=""
PROTO_HOP[C-VLESS-HTTPUpgrade]=""
PROTO_HOP[U-Hysteria2]="4435:4500"
PROTO_HOP[U-TUIC-v5]="11445:11500"
PROTO_HOP[D-AnyTLS]=""
PROTO_HOP[D-NaiveProxy]=""
PROTO_HOP[D-ShadowTLS-SS]=""

# share-link renderer
PROTO_SCHEME[R-VLESS-Vision]=link_RVlessVision
PROTO_SCHEME[R-VLESS-XHTTP]=link_RVlessXHTTP
PROTO_SCHEME[R-VLESS-gRPC]=link_RVlessGRPC
PROTO_SCHEME[C-VLESS-XHTTP]=link_CVlessXHTTP
PROTO_SCHEME[C-VLESS-WS]=link_CVlessWS
PROTO_SCHEME[C-Trojan-WS]=link_CTrojanWS
PROTO_SCHEME[C-VMess-WS]=link_CVmessWS
PROTO_SCHEME[C-VLESS-HTTPUpgrade]=link_CVlessHTTPU
PROTO_SCHEME[U-Hysteria2]=link_UHysteria2
PROTO_SCHEME[U-TUIC-v5]=link_UTuicV5
PROTO_SCHEME[D-AnyTLS]=link_DAnyTLS
PROTO_SCHEME[D-NaiveProxy]=link_DNaive
PROTO_SCHEME[D-ShadowTLS-SS]=link_DShadowTLSSS

# loadState call after: override PROTO_PORT with state.proto_port_override
protoApplyOverride() {
  [[ -f "$STATE_FILE" ]] || return 0
  local pairs
  pairs=$(jq -r '.proto_port_override // {} | to_entries[] | "\(.key) \(.value)"' "$STATE_FILE")
  [[ -z "$pairs" ]] && return 0
  local tag port
  while IFS=' ' read -r tag port; do
    [[ -n "$tag" && -n "$port" ]] || continue
    [[ -n "${PROTO_PORT[$tag]:-}" ]] || continue
    [[ "$tag" == "R-VLESS-Vision" ]] && continue
    PROTO_PORT[$tag]="$port"
  done <<<"$pairs"
}

protoAssertMetadata() {
  local tag
  for tag in "${PROTO_TAGS[@]}"; do
    [[ -n "${PROTO_CORE[$tag]:-}" ]]   || die "PROTO_CORE missing: $tag"
    [[ -n "${PROTO_PORT[$tag]:-}" ]]   || die "PROTO_PORT missing: $tag"
    [[ -n "${PROTO_CDN[$tag]:-}" ]]    || die "PROTO_CDN missing: $tag"
    [[ -v "PROTO_HOP[$tag]" ]]          || die "PROTO_HOP missing: $tag"
    [[ -n "${PROTO_SCHEME[$tag]:-}" ]] || die "PROTO_SCHEME missing: $tag"
  done
}

protoEnabledJson() {
  jq -c '.proto_enabled // ["R-VLESS-Vision"]' "$STATE_FILE"
}

protoEnableOnly() {
  local json=$1
  stateSetJson proto_enabled "$json"
}

# proto_enabled is the only source for the enabled set; all other predicate functions derive from it
protoIsEnabled() {
  local tag=$1
  jq -e --arg t "$tag" \
    '((.proto_enabled // ["R-VLESS-Vision"]) | index($t)) != null' \
    "$STATE_FILE" >/dev/null 2>&1
}

protoIsDisabled() {
  ! protoIsEnabled "$1"
}

# ============ SECTION 12 Xray / sing-box inbound templates ============
# common field retrieval(avoid repeated jq calls)
__inb_uuid() { stateGet uuid; }
__inb_priv() { stateGet reality_privkey; }
__inb_sid()  { stateGet reality_shortid; }
__inb_sni()  { stateGet reality_sni; }

# Reality shared streamSettings fragment for the three Reality protocols
__reality_stream() {
  local network=$1
  local extra="${2:-}"
  [[ -n "$extra" ]] || extra='{}'
  local sni; sni=$(__inb_sni)
  local priv; priv=$(__inb_priv)
  local sid; sid=$(__inb_sid)
  local mldsa; mldsa=$(stateGet reality_mldsa65_enabled)
  local seed; seed=$(stateGet reality_mldsa65_seed)
  local server_names; server_names=$(jq -c '.sni_grace_server_names // []' "$STATE_FILE")
  if [[ "$server_names" == "[]" || -z "$server_names" ]]; then
    server_names=$(jq -n --arg a "$sni" '[$a]')
  fi
  jq -n --arg net "$network" --arg sni "$sni" --arg priv "$priv" \
        --arg sid "$sid" --arg seed "$seed" \
        --argjson names "$server_names" --argjson mldsa "${mldsa:-false}" \
        --argjson extra "$extra" '
    ({
      network: $net,
      security: "reality",
      realitySettings: ({
        target: ($sni+":443"),
        serverNames: $names,
        privateKey: $priv,
        shortIds: [$sid]
      } + (if $mldsa and ($seed|length>0) then {mldsa65Seed:$seed} else {} end))
    } + $extra)'
}

# 1) R-VLESS-Vision (port 443)
xrayInbound_RVlessVision() {
  local port="${PROTO_PORT[R-VLESS-Vision]}"
  local uuid; uuid=$(__inb_uuid)
  local stream; stream=$(__reality_stream tcp '{}')
  jq -n --arg tag "R-VLESS-Vision" --argjson port "$port" --arg uuid "$uuid" \
        --argjson stream "$stream" '
    { tag:$tag, listen:"0.0.0.0", port:$port, protocol:"vless",
      settings: { clients:[{id:$uuid, flow:"xtls-rprx-vision"}], decryption:"none" },
      streamSettings:$stream }'
}

# 2) R-VLESS-XHTTP (port 8443)
xrayInbound_RVlessXHTTP() {
  local port="${PROTO_PORT[R-VLESS-XHTTP]}"
  local uuid; uuid=$(__inb_uuid)
  local path; path=$(stateGet xhttp_path)
  [[ -n "$path" ]] || path="/xh"
  local extra; extra=$(jq -n --arg path "$path" '{xhttpSettings:{path:$path}}')
  local stream; stream=$(__reality_stream xhttp "$extra")
  jq -n --arg tag "R-VLESS-XHTTP" --argjson port "$port" --arg uuid "$uuid" \
        --argjson stream "$stream" '
    { tag:$tag, listen:"0.0.0.0", port:$port, protocol:"vless",
      settings: { clients:[{id:$uuid}], decryption:"none" },
      streamSettings:$stream }'
}

# 3) R-VLESS-gRPC (port 2053)
xrayInbound_RVlessGRPC() {
  local port="${PROTO_PORT[R-VLESS-gRPC]}"
  local uuid; uuid=$(__inb_uuid)
  local service; service=$(stateGet grpc_service_name)
  [[ -n "$service" ]] || service="grpc"
  local extra; extra=$(jq -n --arg service "$service" '{grpcSettings:{serviceName:$service}}')
  local stream; stream=$(__reality_stream grpc "$extra")
  jq -n --arg tag "R-VLESS-gRPC" --argjson port "$port" --arg uuid "$uuid" \
        --argjson stream "$stream" '
    { tag:$tag, listen:"0.0.0.0", port:$port, protocol:"vless",
      settings: { clients:[{id:$uuid}], decryption:"none" },
      streamSettings:$stream }'
}

# 4) C-VLESS-WS (loopback 31001)
xrayInbound_CVlessXHTTP() {
  local port="${PROTO_PORT[C-VLESS-XHTTP]}"
  local uuid; uuid=$(__inb_uuid)
  local path; path=$(cdnPath C-VLESS-XHTTP)
  jq -n --arg tag "C-VLESS-XHTTP" --argjson port "$port" --arg uuid "$uuid" --arg path "$path" '
    { tag:$tag, listen:"127.0.0.1", port:$port, protocol:"vless",
      settings: { clients:[{id:$uuid}], decryption:"none" },
      streamSettings: { network:"xhttp", security:"none", xhttpSettings:{path:$path} } }'
}

# 5) C-VLESS-WS (loopback 31001)
xrayInbound_CVlessWS() {
  local port="${PROTO_PORT[C-VLESS-WS]}"
  local uuid; uuid=$(__inb_uuid)
  local path; path=$(cdnPath C-VLESS-WS)
  jq -n --arg tag "C-VLESS-WS" --argjson port "$port" --arg uuid "$uuid" --arg path "$path" '
    { tag:$tag, listen:"127.0.0.1", port:$port, protocol:"vless",
      settings: { clients:[{id:$uuid}], decryption:"none" },
      streamSettings: { network:"ws", security:"none", wsSettings:{path:$path} } }'
}

# 6) C-Trojan-WS (loopback 31002)
xrayInbound_CTrojanWS() {
  local port="${PROTO_PORT[C-Trojan-WS]}"
  local uuid; uuid=$(__inb_uuid)
  local path; path=$(cdnPath C-Trojan-WS)
  jq -n --arg tag "C-Trojan-WS" --argjson port "$port" --arg uuid "$uuid" --arg path "$path" '
    { tag:$tag, listen:"127.0.0.1", port:$port, protocol:"trojan",
      settings: { clients:[{password:$uuid}] },
      streamSettings: { network:"ws", security:"none", wsSettings:{path:$path} } }'
}

# 7) C-VMess-WS (loopback 31003)
xrayInbound_CVmessWS() {
  local port="${PROTO_PORT[C-VMess-WS]}"
  local uuid; uuid=$(__inb_uuid)
  local path; path=$(cdnPath C-VMess-WS)
  jq -n --arg tag "C-VMess-WS" --argjson port "$port" --arg uuid "$uuid" --arg path "$path" '
    { tag:$tag, listen:"127.0.0.1", port:$port, protocol:"vmess",
      settings: { clients:[{id:$uuid, alterId:0}] },
      streamSettings: { network:"ws", security:"none", wsSettings:{path:$path} } }'
}

# 8) C-VLESS-HTTPUpgrade (loopback 31004)
xrayInbound_CVlessHTTPU() {
  local port="${PROTO_PORT[C-VLESS-HTTPUpgrade]}"
  local uuid; uuid=$(__inb_uuid)
  local path; path=$(cdnPath C-VLESS-HTTPUpgrade)
  jq -n --arg tag "C-VLESS-HTTPUpgrade" --argjson port "$port" --arg uuid "$uuid" --arg path "$path" '
    { tag:$tag, listen:"127.0.0.1", port:$port, protocol:"vless",
      settings: { clients:[{id:$uuid}], decryption:"none" },
      streamSettings: { network:"httpupgrade", security:"none",
                        httpupgradeSettings:{path:$path} } }'
}

# 8) U-Hysteria2 (sbox, 4433)
sboxInbound_UHysteria2() {
  local port="${PROTO_PORT[U-Hysteria2]}"
  local uuid; uuid=$(__inb_uuid)
  local obfs; obfs=$(stateGet hy2_obfs_password)
  jq -n --arg tag "U-Hysteria2" --argjson port "$port" --arg uuid "$uuid" \
        --arg cert "$CERT_FULLCHAIN" --arg key "$CERT_KEY" --arg obfs "$obfs" '
    { type:"hysteria2", tag:$tag, listen:"::", listen_port:$port,
      users:[{password:$uuid}],
      obfs:{type:"salamander", password:$obfs},
      tls:{enabled:true, alpn:["h3"], certificate_path:$cert, key_path:$key} }'
}

# 9) U-TUIC-v5 (sbox, 11443)
sboxInbound_UTuicV5() {
  local port="${PROTO_PORT[U-TUIC-v5]}"
  local uuid; uuid=$(__inb_uuid)
  local pwd; pwd=$(stateGet tuic_password)
  jq -n --arg tag "U-TUIC-v5" --argjson port "$port" --arg uuid "$uuid" --arg pwd "$pwd" \
        --arg cert "$CERT_FULLCHAIN" --arg key "$CERT_KEY" '
    { type:"tuic", tag:$tag, listen:"::", listen_port:$port,
      users:[{uuid:$uuid, password:$pwd}],
      congestion_control:"bbr",
      tls:{enabled:true, alpn:["h3"], certificate_path:$cert, key_path:$key} }'
}

# 10) D-AnyTLS (sbox, 8444)
sboxInbound_DAnyTLS() {
  local port="${PROTO_PORT[D-AnyTLS]}"
  local uuid; uuid=$(__inb_uuid)
  jq -n --arg tag "D-AnyTLS" --argjson port "$port" --arg uuid "$uuid" \
        --arg cert "$CERT_FULLCHAIN" --arg key "$CERT_KEY" '
    { type:"anytls", tag:$tag, listen:"::", listen_port:$port,
      users:[{password:$uuid}],
      tls:{enabled:true, certificate_path:$cert, key_path:$key} }'
}

# 11) D-NaiveProxy (sbox, 10443)
sboxInbound_DNaive() {
  local port="${PROTO_PORT[D-NaiveProxy]}"
  local uuid; uuid=$(__inb_uuid)
  jq -n --arg tag "D-NaiveProxy" --argjson port "$port" --arg uuid "$uuid" \
        --arg cert "$CERT_FULLCHAIN" --arg key "$CERT_KEY" '
    { type:"naive", tag:$tag, listen:"::", listen_port:$port,
      users:[{username:"root", password:$uuid}],
      tls:{enabled:true, certificate_path:$cert, key_path:$key} }'
}

# 12) D-ShadowTLS-SS (sbox, 9443)
shadowTlsInnerTag() { printf 'ss-inner-janus'; }

sboxInbound_DShadowTLSSS() {
  local port="${PROTO_PORT[D-ShadowTLS-SS]}"
  local pwd; pwd=$(stateGet shadowtls_password)
  local sni; sni=$(__inb_sni)
  local detour; detour=$(shadowTlsInnerTag)
  jq -n --arg tag "D-ShadowTLS-SS" --argjson port "$port" --arg pwd "$pwd" \
        --arg sni "$sni" --arg detour "$detour" '
    { type:"shadowtls", tag:$tag, listen:"::", listen_port:$port,
      version:3,
      users:[{password:$pwd}],
      handshake:{server:$sni, server_port:443},
      strict_mode:true,
      detour:$detour }'
}

# companion internal SS inbound(bound to detour)
sboxInbound_DShadowTLSSS_Inner() {
  local detour; detour=$(shadowTlsInnerTag)
  local method; method=$(stateGet shadowtls_ss_method)
  local pwd; pwd=$(stateGet shadowtls_ss_password)
  jq -n --arg tag "$detour" --arg method "$method" --arg pwd "$pwd" '
    { type:"shadowsocks", tag:$tag, listen:"127.0.0.1", listen_port:10453,
      network:"tcp",
      method:$method,
      password:$pwd }'
}

xrayConfigBuildFile() {
  local tmp=$1
  loadState
  stateEnsureProtocolSecrets
  protoApplyOverride

  local frags=()
  local tag
  for tag in "${PROTO_TAGS[@]}"; do
    [[ "${PROTO_CORE[$tag]}" == "xray" ]] || continue
    protoIsDisabled "$tag" && continue
    case "$tag" in
      R-VLESS-Vision)    frags+=("$(xrayInbound_RVlessVision)") ;;
      R-VLESS-XHTTP)     frags+=("$(xrayInbound_RVlessXHTTP)")  ;;
      R-VLESS-gRPC)      frags+=("$(xrayInbound_RVlessGRPC)")   ;;
      C-VLESS-XHTTP)     frags+=("$(xrayInbound_CVlessXHTTP)")  ;;
      C-VLESS-WS)        frags+=("$(xrayInbound_CVlessWS)")     ;;
      C-Trojan-WS)       frags+=("$(xrayInbound_CTrojanWS)")    ;;
      C-VMess-WS)        frags+=("$(xrayInbound_CVmessWS)")     ;;
      C-VLESS-HTTPUpgrade) frags+=("$(xrayInbound_CVlessHTTPU)") ;;
    esac
  done

  local inbounds_json
  inbounds_json=$(printf '%s\n' "${frags[@]}" | jq -s '.')

  jq -n --argjson inb "$inbounds_json" '
    {
      log:{loglevel:"warning"},
      inbounds:$inb,
      outbounds:[
        {protocol:"freedom",  tag:"direct"},
        {protocol:"blackhole",tag:"blocked"}
      ],
      routing:{
        domainStrategy:"AsIs",
        rules:[
          {type:"field", ip:[
            "0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8",
            "169.254.0.0/16","172.16.0.0/12","192.0.0.0/24",
            "192.0.2.0/24","192.168.0.0/16","198.18.0.0/15",
            "198.51.100.0/24","203.0.113.0/24","224.0.0.0/4",
            "::1/128","fc00::/7","fe80::/10"
          ], outboundTag:"blocked"}
        ]
      }
    }' > "$tmp"
}

# xrayConfigAssemble: assemble all Xray inbounds
xrayConfigAssemble() {
  mkdir -p "$XRAY_DIR"
  local tmp; tmp=$(mktemp --suffix=.json)
  xrayConfigBuildFile "$tmp"
  if ! "$XRAY_BIN" run -test -c "$tmp" >/dev/null 2>&1; then
    "$XRAY_BIN" run -test -c "$tmp" 2>&1 | head -n 30 >&2
    rm -f "$tmp"
    die "Xray config validation failed"
  fi
  mv "$tmp" "$XRAY_CONFIG"
  chmod 600 "$XRAY_CONFIG"
  ok "written $XRAY_CONFIG"
}

sboxConfigBuildFile() {
  local tmp=$1
  loadState
  stateEnsureProtocolSecrets
  protoApplyOverride

  local frags=()
  local tag
  for tag in "${PROTO_TAGS[@]}"; do
    [[ "${PROTO_CORE[$tag]}" == "sbox" ]] || continue
    protoIsDisabled "$tag" && continue
    case "$tag" in
      U-Hysteria2)    frags+=("$(sboxInbound_UHysteria2)") ;;
      U-TUIC-v5)      frags+=("$(sboxInbound_UTuicV5)")    ;;
      D-AnyTLS)       frags+=("$(sboxInbound_DAnyTLS)")    ;;
      D-NaiveProxy)   frags+=("$(sboxInbound_DNaive)")     ;;
      D-ShadowTLS-SS)
        frags+=("$(sboxInbound_DShadowTLSSS)")
        frags+=("$(sboxInbound_DShadowTLSSS_Inner)")
        ;;
    esac
  done

  local inbounds_json
  inbounds_json=$(printf '%s\n' "${frags[@]}" | jq -s '.')

  jq -n --argjson inb "$inbounds_json" '
    {
      log:{level:"warn", timestamp:true},
      inbounds:$inb,
      outbounds:[
        {type:"direct",  tag:"direct"},
        {type:"block",   tag:"blocked"}
      ]
    }' > "$tmp"
}

# sboxConfigAssemble: assemble sing-box inbounds
sboxConfigAssemble() {
  mkdir -p "$SBOX_DIR"
  local tmp; tmp=$(mktemp --suffix=.json)
  sboxConfigBuildFile "$tmp"
  if ! "$SBOX_BIN" check -c "$tmp" >/dev/null 2>&1; then
    "$SBOX_BIN" check -c "$tmp" 2>&1 | head -n 30 >&2
    rm -f "$tmp"
    die "sing-box config validation failed"
  fi
  mv "$tmp" "$SBOX_CONFIG"
  chmod 600 "$SBOX_CONFIG"
  ok "written $SBOX_CONFIG"
}

# ============ SECTION 13 systemd unit writing ============
unitXray() {
  cat > "/etc/systemd/system/${UNIT_XRAY}" <<EOF
[Unit]
Description=janus Xray
After=network-online.target ${UNIT_HOP}
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -c ${XRAY_CONFIG}
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
}

unitSingBox() {
  cat > "/etc/systemd/system/${UNIT_SBOX}" <<EOF
[Unit]
Description=janus sing-box
After=network-online.target ${UNIT_HOP}
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SBOX_BIN} -D ${SBOX_DIR} run -c ${SBOX_CONFIG}
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
}

unitCloudflared() {
  cat > "/etc/systemd/system/${UNIT_CFD}" <<EOF
[Unit]
Description=janus cloudflared tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-${CFD_DIR}/env
# Read token into TUNNEL_TOKEN env var (cloudflared honors it) instead of passing it
# as --token argv. /bin/sh runs the script literal — \$(cat ...) is a sh-level
# substitution, so the token never appears in /proc/<pid>/cmdline of either sh or
# cloudflared. cloudflared inherits TUNNEL_TOKEN via env only.
ExecStart=/bin/sh -c 'TUNNEL_TOKEN=\$(cat ${CFD_TOKEN_FILE}); export TUNNEL_TOKEN; exec ${CFD_BIN} tunnel --no-autoupdate run'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

unitSub() {
  local port; port=$(stateGet sub_darkhttpd_port)
  port="${port:-$DARKHTTPD_PORT_DEFAULT}"
  local socat_bin
  socat_bin="$(command -v socat || true)"
  [[ -x "$socat_bin" ]] || die "socat is missing; run system dependencies first"
  [[ -x "$INSTALL_SH_DEST" ]] || die "${INSTALL_SH_DEST} is missing or not executable; install/repair the subscription service first"
  cat > "/etc/systemd/system/${UNIT_SUB}" <<EOF
[Unit]
Description=janus subscription responder
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/sh -c 'exec ${socat_bin} -T 30 TCP-LISTEN:${port},bind=127.0.0.1,reuseaddr,fork SYSTEM:"${INSTALL_SH_DEST} subserve"'
Restart=always
RestartSec=3
# socat exits with 143 after SIGTERM. systemd treats that as failure by default, which keeps the logs RED.
# Treat 143 as a successful exit too, while preserving 0 and allowing graceful stop/restart exits.
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF
}

unitHop() {
  loadState
  protoApplyOverride
  local h2 tu
  h2="${PROTO_HOP[U-Hysteria2]}"
  tu="${PROTO_HOP[U-TUIC-v5]}"
  local h2_main="${PROTO_PORT[U-Hysteria2]}"
  local tu_main="${PROTO_PORT[U-TUIC-v5]}"
  local h2_s="${h2%%:*}" h2_e="${h2##*:}"
  local tu_s="${tu%%:*}" tu_e="${tu##*:}"
  local exec_lines=""
  if ! protoIsDisabled "U-Hysteria2" && [[ -n "$h2" ]]; then
    exec_lines+="ExecStart=/sbin/iptables  -t nat -A PREROUTING -p udp --dport ${h2_s}:${h2_e} -j REDIRECT --to-ports ${h2_main} -m comment --comment janus_hop_h2_v4"$'\n'
    exec_lines+="ExecStart=/sbin/ip6tables -t nat -A PREROUTING -p udp --dport ${h2_s}:${h2_e} -j REDIRECT --to-ports ${h2_main} -m comment --comment janus_hop_h2_v6"$'\n'
  fi
  if ! protoIsDisabled "U-TUIC-v5" && [[ -n "$tu" ]]; then
    exec_lines+="ExecStart=/sbin/iptables  -t nat -A PREROUTING -p udp --dport ${tu_s}:${tu_e} -j REDIRECT --to-ports ${tu_main} -m comment --comment janus_hop_tu_v4"$'\n'
    exec_lines+="ExecStart=/sbin/ip6tables -t nat -A PREROUTING -p udp --dport ${tu_s}:${tu_e} -j REDIRECT --to-ports ${tu_main} -m comment --comment janus_hop_tu_v6"$'\n'
  fi
  [[ -n "$exec_lines" ]] || exec_lines="ExecStart=/bin/true"$'\n'

  cat > "/etc/systemd/system/${UNIT_HOP}" <<EOF
[Unit]
Description=janus UDP port hopping (iptables NAT)
After=network-online.target
Before=${UNIT_XRAY} ${UNIT_SBOX}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sh -c 'iptables-save -t nat 2>/dev/null | grep -E "janus_hop_" | sed "s/^-A /iptables -t nat -D /" | sh 2>/dev/null; ip6tables-save -t nat 2>/dev/null | grep -E "janus_hop_" | sed "s/^-A /ip6tables -t nat -D /" | sh 2>/dev/null; true'
${exec_lines}ExecStop=/bin/sh -c 'iptables-save -t nat 2>/dev/null | grep -E "janus_hop_" | sed "s/^-A /iptables -t nat -D /" | sh 2>/dev/null; ip6tables-save -t nat 2>/dev/null | grep -E "janus_hop_" | sed "s/^-A /ip6tables -t nat -D /" | sh 2>/dev/null; true'

[Install]
WantedBy=multi-user.target
EOF
}

unitSniRotate() {
  cat > "/etc/systemd/system/${UNIT_SNI_S}" <<EOF
[Unit]
Description=janus SNI rotate (oneshot)
After=network-online.target

[Service]
Type=oneshot
ExecStart=${CLI_PATH} sni check
EOF
  cat > "/etc/systemd/system/${UNIT_SNI_T}" <<EOF
[Unit]
Description=janus SNI rotate timer (daily)

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=2h
Persistent=true
Unit=${UNIT_SNI_S}

[Install]
WantedBy=timers.target
EOF
}

unitCfst() {
  cat > "/etc/systemd/system/${UNIT_CFST_S}" <<EOF
[Unit]
Description=janus CloudflareSpeedTest preferred IP refresh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=JANUS_CFST_AUTO=1
ExecStart=${CLI_PATH} cfst refresh
EOF
  cat > "/etc/systemd/system/${UNIT_CFST_T}" <<EOF
[Unit]
Description=janus CloudflareSpeedTest timer (daily 04:00-06:00)

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=2h
Persistent=true
Unit=${UNIT_CFST_S}

[Install]
WantedBy=timers.target
EOF
}

cfstTimerApply() {
  # quickInstall / unit rewrite / restore only write unit files; timer start/stop follows cfst_enabled only.
  if [[ "$(stateGet cfst_enabled)" == "true" ]]; then
    systemctl enable --now "$UNIT_CFST_T" >/dev/null 2>&1 || warn "janus-cfst.timer enable failed"
  else
    systemctl disable --now "$UNIT_CFST_T" >/dev/null 2>&1 || true
  fi
}

unitAcmeRenew() {
  cat > "/etc/systemd/system/${UNIT_ACME_S}" <<EOF
[Unit]
Description=janus acme.sh renew (oneshot)
After=network-online.target

[Service]
Type=oneshot
ExecStart=${ACME_BIN} --cron --home ${ACME_HOME}
EOF
  cat > "/etc/systemd/system/${UNIT_ACME_T}" <<EOF
[Unit]
Description=janus acme.sh renew timer (daily 04:00)

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=1h
Persistent=true
Unit=${UNIT_ACME_S}

[Install]
WantedBy=timers.target
EOF
}

advRewriteUnits() {
  banner "Force-rewrite all systemd units"
  unitXray; unitSingBox; unitCloudflared; unitSub
  unitHop; unitSniRotate; unitCfst; unitAcmeRenew
  systemctl daemon-reload
  local u
  for u in "$UNIT_HOP" "$UNIT_XRAY" "$UNIT_SBOX" "$UNIT_CFD" "$UNIT_SUB"; do
    systemctl enable "$u" >/dev/null 2>&1 || true
    systemctl restart "$u" 2>/dev/null || true
  done
  systemctl enable --now "$UNIT_SNI_T" >/dev/null 2>&1 || true
  cfstTimerApply
  systemctl enable --now "$UNIT_ACME_T" >/dev/null 2>&1 || true
  ok "11 units rewritten and restarted"
}

# ============ SECTION 14 Cloudflare Tunnel orchestration ============
cfTunnelProvision() {
  loadState
  local name; name=$(stateGet cf_tunnel_name)
  if [[ -z "$name" ]]; then
    name="edge-${ROOT_DOMAIN//./-}-$(openssl rand -hex 3)"
    stateSet cf_tunnel_name "$name"
  fi
  local tid; tid=$(stateGet cf_tunnel_id)
  if [[ -n "$tid" ]]; then
    if cfTunnelGet "$tid" >/dev/null 2>&1; then
      log "Reusing tunnel: $tid"
    else
      warn "tunnel_id in state is invalid; recreating it"
      tid=""
    fi
  fi
  if [[ -z "$tid" ]]; then
    tid=$(cfTunnelCreate "$name")
    [[ -n "$tid" ]] || die "failed to create tunnel"
    stateSet cf_tunnel_id "$tid"
  fi
  local token; token=$(cfTunnelToken "$tid")
  [[ -n "$token" ]] || die "failed to get tunnel token"
  mkdir -p "$CFD_DIR"
  printf '%s' "$token" > "$CFD_TOKEN_FILE"
  chmod 600 "$CFD_TOKEN_FILE"
  ok "Tunnel provisioned: $tid"
}

cfTunnelIngressBuild() {
  loadState
  protoApplyOverride
  local cdn_host="${SUB_CDN}.${ROOT_DOMAIN}"
  local sub_host="${SUB_SUB}.${ROOT_DOMAIN}"
  local sub_port; sub_port=$(stateGet sub_darkhttpd_port)
  sub_port="${sub_port:-$DARKHTTPD_PORT_DEFAULT}"
  jq -n --arg cdn "$cdn_host" --arg sub "$sub_host" --arg subp "$sub_port" \
        --arg px "$(cdnPathGlob C-VLESS-XHTTP)" \
        --arg pw "$(cdnPathGlob C-VLESS-WS)" \
        --arg pt "$(cdnPathGlob C-Trojan-WS)" \
        --arg pm "$(cdnPathGlob C-VMess-WS)" \
        --arg pu "$(cdnPathGlob C-VLESS-HTTPUpgrade)" \
        --argjson port_x "${PROTO_PORT[C-VLESS-XHTTP]}" \
        --argjson port_w "${PROTO_PORT[C-VLESS-WS]}" \
        --argjson port_t "${PROTO_PORT[C-Trojan-WS]}" \
        --argjson port_m "${PROTO_PORT[C-VMess-WS]}" \
        --argjson port_u "${PROTO_PORT[C-VLESS-HTTPUpgrade]}" '
    { ingress: [
        { hostname:$cdn, path:$px, service:("http://127.0.0.1:"+($port_x|tostring)) },
        { hostname:$cdn, path:$pw, service:("http://127.0.0.1:"+($port_w|tostring)) },
        { hostname:$cdn, path:$pt, service:("http://127.0.0.1:"+($port_t|tostring)) },
        { hostname:$cdn, path:$pm, service:("http://127.0.0.1:"+($port_m|tostring)) },
        { hostname:$cdn, path:$pu, service:("http://127.0.0.1:"+($port_u|tostring)) },
        { hostname:$sub, service:("http://127.0.0.1:"+$subp) },
        { service:"http_status:404" }
      ]
    }'
}

cfDnsBootstrap() {
  banner "Provision DNS for the r./cdn./sub. subdomains"
  loadState
  local ipv4; ipv4=$(stateGet ipv4)
  local ipv6; ipv6=$(stateGet ipv6)
  local r_host="${SUB_R}.${ROOT_DOMAIN}"
  local cdn_host="${SUB_CDN}.${ROOT_DOMAIN}"
  local sub_host="${SUB_SUB}.${ROOT_DOMAIN}"

  # r.<root>: A direct
  cfRecordDelete "$r_host" A
  cfRecordDelete "$r_host" AAAA
  cfRecordDelete "$r_host" CNAME
  if [[ -z "$ipv4" ]]; then
    detectPublicIp
    ipv4=$(stateGet ipv4); ipv6=$(stateGet ipv6)
  fi
  [[ -n "$ipv4" ]] && cfRecordUpsert "$r_host" A "$ipv4" false
  [[ -n "$ipv6" ]] && cfRecordUpsert "$r_host" AAAA "$ipv6" false

  # cdn./sub.: CNAME -> <tid>.cfargotunnel.com proxied=true
  cfRecordDelete "$cdn_host" A
  cfRecordDelete "$cdn_host" AAAA
  cfRecordDelete "$cdn_host" CNAME
  cfDnsRouteUpsert "$cdn_host"

  cfRecordDelete "$sub_host" A
  cfRecordDelete "$sub_host" AAAA
  cfRecordDelete "$sub_host" CNAME
  cfDnsRouteUpsert "$sub_host"

  # assert r.<root> direct record (A for IPv4, AAAA for IPv6-only host) proxied=false
  local zid; zid=$(cfZoneId)
  local rec_type rec_val
  if [[ -n "$ipv4" ]]; then
    rec_type="A"; rec_val="$ipv4"
  elif [[ -n "$ipv6" ]]; then
    rec_type="AAAA"; rec_val="$ipv6"
  else
    die "Could not detect any public IP (IPv4 or IPv6) for r.${ROOT_DOMAIN}"
  fi
  local check prox content i
  for i in {1..10}; do
    check=$(cfApi GET "/zones/${zid}/dns_records?name=${r_host}&type=${rec_type}")
    prox=$(jq -r '.result[0].proxied | tostring' <<<"$check")
    content=$(jq -r '.result[0].content // empty' <<<"$check")
    [[ "$prox" == "false" && "$content" == "$rec_val" ]] && break
    sleep 2
  done
  [[ "$prox" == "false" && "$content" == "$rec_val" ]] || die "r.${ROOT_DOMAIN} must be ${rec_type}=${rec_val} and proxied=false, please check"

  ok "DNS provisioned: r./cdn./sub.${ROOT_DOMAIN}"
}

cfTunnelRebuild() {
  banner "Rebuild the Cloudflare CDN/Tunnel entry"
  confirm "Confirm rebuilding the Cloudflare CDN/Tunnel entry?" || return 0
  loadState
  local tid; tid=$(stateGet cf_tunnel_id)
  if [[ -n "$tid" ]]; then
    cfTunnelDelete "$tid" || true
    stateSet cf_tunnel_id ""
  fi
  cfTunnelProvision
  local cfg; cfg=$(cfTunnelIngressBuild)
  cfTunnelConfigPut "$(stateGet cf_tunnel_id)" "$cfg"
  cfDnsBootstrap
  systemctl restart "$UNIT_CFD" 2>/dev/null || true
  subRegenAllCore || true
  ok "Cloudflare CDN/Tunnel entry rebuilt"
}

cfTunnelStatus() {
  banner "Cloudflare Tunnel status"
  loadState
  local tid; tid=$(stateGet cf_tunnel_id)
  [[ -n "$tid" ]] || { warn "no tunnel has been created"; return 0; }
  local resp; resp=$(cfTunnelGet "$tid")
  printf 'tunnel id: %s\n' "$tid"
  printf 'name     : %s\n' "$(jq -r '.result.name // ""' <<<"$resp")"
  printf 'status   : %s\n' "$(jq -r '.result.status // ""' <<<"$resp")"
  printf 'conn_act : %s\n' "$(jq -r '.result.connections | length' <<<"$resp")"
}

cfDnsShow() {
  banner "DNS record overview"
  loadState
  local zid; zid=$(cfZoneId)
  local n
  for n in "${SUB_R}.${ROOT_DOMAIN}" "${SUB_CDN}.${ROOT_DOMAIN}" "${SUB_SUB}.${ROOT_DOMAIN}"; do
    local r; r=$(cfApi GET "/zones/${zid}/dns_records?name=${n}")
    jq -r '.result[] | "\(.name) \(.type) proxied=\(.proxied) ttl=\(.ttl) content=\(.content)"' <<<"$r"
  done
}

cfSetToken() {
  banner "Set Cloudflare API Token"
  local t; prompt t "New token"
  [[ -n "$t" ]] || return 1
  CF_API_TOKEN="$t"
  cfTokenPreflight
  printf '%s' "$t" > "$CF_TOKEN_FILE"
  chmod 600 "$CF_TOKEN_FILE"
  ok "Token updated"
}

cfTunnelDeleteMenu() {
  banner "Delete Tunnel only(keep DNS)"
  local tid; tid=$(stateGet cf_tunnel_id)
  [[ -n "$tid" ]] || { warn "no tunnel to delete"; return 0; }
  cfTunnelDelete "$tid"
  stateSet cf_tunnel_id ""
  ok "Tunnel deleted"
}

cfDnsReissue() {
  cfDnsBootstrap
}

cfRecordDeleteInZone() {
  local zid=$1 name=$2 type=$3 rid resp
  resp=$(cfApi GET "/zones/${zid}/dns_records?type=${type}&name=${name}" 2>/dev/null) || return 0
  jq -r '.result[]?.id // empty' <<<"$resp" | while read -r rid; do
    [[ -n "$rid" ]] || continue
    cfApi DELETE "/zones/${zid}/dns_records/${rid}" >/dev/null 2>&1 || true
  done
}

cfCleanupOldDomainRecords() {
  local old_domain=$1 old_zone=$2
  [[ -n "$old_domain" && -n "$old_zone" ]] || return 0
  local n t
  for n in "${SUB_R}.${old_domain}" "${SUB_CDN}.${old_domain}" "${SUB_SUB}.${old_domain}"; do
    for t in A AAAA CNAME; do
      cfRecordDeleteInZone "$old_zone" "$n" "$t" || true
    done
  done
}

cfDomainMigrate() {
  banner "Domain migration"
  loadState
  local new_root="${1:-}" old_root old_zone old_token old_tid old_root_env backup_state backup_cert okflag=0
  old_root=$(stateGet domain)
  old_zone=$(stateGet cf_zone_id)
  old_token=$(stateGet sub_token)
  old_tid=$(stateGet cf_tunnel_id)
  [[ -n "$new_root" ]] || prompt new_root "Enter the new root domain(must be hosted on Cloudflare)"
  new_root=$(printf '%s' "$new_root" | tr '[:upper:]' '[:lower:]' | tr -d ' \r\n\t')
  [[ "$new_root" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] || die "invalid new root domain: $new_root"
  [[ "$new_root" != "$old_root" ]] || { warn "new and old domains are the same; migration is not needed"; return 0; }

  # 1. Side-effect-free preflight: confirm the token can list the new zone without touching state.
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    [[ -r "$CF_TOKEN_FILE" ]] || die "CF_API_TOKEN is not set and ${CF_TOKEN_FILE} is not readable; state was not changed"
    CF_API_TOKEN=$(<"$CF_TOKEN_FILE")
    export CF_API_TOKEN
  fi
  local pre_resp pre_zid pre_hfile
  pre_hfile=$(__cfAuthHeaderFile) || die "could not prepare CF auth header; state was not changed"
  pre_resp=$(curl -fsS --max-time 10 \
    -H "@${pre_hfile}" \
    "${CF_API_BASE}/zones?name=${new_root}" 2>/dev/null || true)
  rm -f "$pre_hfile"
  pre_zid=$(jq -r '.result[0].id // empty' <<<"$pre_resp" 2>/dev/null || true)
  [[ -n "$pre_zid" ]] || die "new domain ${new_root} is outside the token scope or the token lacks permission; state was not changed"

  warn "Migration will switch the certificate, DNS, Tunnel ingress, and subscription URL, and force-rotate sub_token; old subscriptions will no longer work."
  local ans; read -r -p "Type MIGRATE to confirm: " ans || true
  [[ "$ans" == "MIGRATE" ]] || { warn "canceled"; return 0; }

  backup_state=$(mktemp)
  backup_cert=$(mktemp -d)
  cp -a "$STATE_FILE" "$backup_state"
  cp -a "$CERT_DIR"/. "$backup_cert"/ 2>/dev/null || true
  old_root_env="${ROOT_DOMAIN:-}"

  # 2. cache the old ingress config so the remote side can be rolled back on failure
  local old_ingress_cfg=""
  if [[ -n "$old_tid" ]]; then
    old_ingress_cfg=$(cfApi GET "/accounts/$(cfAccountId)/cfd_tunnel/${old_tid}/configurations" 2>/dev/null \
      | jq -c '.result.config // empty' 2>/dev/null || true)
  fi

  if (
    ROOT_DOMAIN="$new_root"; export ROOT_DOMAIN
    stateSet domain "$new_root"
    stateSet cf_zone_id ""
    # Clear tunnel name so cfTunnelProvision regenerates an edge name from the new root domain.
    stateSet cf_tunnel_name ""
    cfTokenPreflight
    acmeInstall
    acmeIssue
    acmeInstallCert
    stateSet sub_token "$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"
    cfTunnelProvision
    cfTunnelConfigPut "$(stateGet cf_tunnel_id)" "$(cfTunnelIngressBuild)"
    cfDnsBootstrap
    xrayConfigAssemble
    sboxConfigAssemble
    subRegenAllCore
    systemctl restart "$UNIT_XRAY" "$UNIT_SBOX" "$UNIT_CFD" "$UNIT_SUB" 2>/dev/null || true
  ); then
    okflag=1
  fi

  if (( ! okflag )); then
    warn "domain migration failed; rolling back state, certificate, and remote ingress"
    cp -a "$backup_state" "$STATE_FILE"
    rm -rf "$CERT_DIR"
    mkdir -p "$CERT_DIR"
    cp -a "$backup_cert"/. "$CERT_DIR"/ 2>/dev/null || true
    chmod 600 "$STATE_FILE"
    ROOT_DOMAIN="$old_root_env"; export ROOT_DOMAIN
    # Switch the remote Tunnel ingress back to the old domain. First try PUT with the cached value;
    # if the cache is empty, rebuild an ingress config with cfTunnelIngressBuild.
    if [[ -n "$old_tid" ]]; then
      if [[ -n "$old_ingress_cfg" && "$old_ingress_cfg" != "null" ]]; then
        cfApi PUT "/accounts/$(cfAccountId)/cfd_tunnel/${old_tid}/configurations" \
          "$(jq -n --argjson c "$old_ingress_cfg" '{config:$c}')" >/dev/null 2>&1 \
          || warn "ingress cache rollback failed; trying to rebuild with the old domain"
      fi
      if ! cfTunnelConfigPut "$old_tid" "$(cfTunnelIngressBuild)" >/dev/null 2>&1; then
        warn 'Tunnel ingress rollback failed; manually run `janus cf tunnel` to check'
      fi
    fi
    rm -f "$backup_state"; rm -rf "$backup_cert"
    return 1
  fi

  ROOT_DOMAIN="$new_root"; export ROOT_DOMAIN
  [[ -n "$old_token" ]] && rm -rf "${WEBROOT:?}/${old_token}" 2>/dev/null || true
  if [[ -n "$old_root" && -n "$old_zone" ]]; then
    cfCleanupOldDomainRecords "$old_root" "$old_zone" || warn "old-domain DNS cleanup failed; check manually later"
  fi
  rm -f "$backup_state"; rm -rf "$backup_cert"
  ok "Domain migration completed: ${old_root:-not set} -> ${new_root}"
  subShow
}

cfCdnEditIngress() {
  banner "Edit the cdn subdomain upstream"
  log "Current ingress: "
  local tid; tid=$(stateGet cf_tunnel_id)
  cfApi GET "/accounts/$(cfAccountId)/cfd_tunnel/${tid}/configurations" \
    | jq -r '.result.config.ingress[] | "\(.hostname // "*") \(.path // "*") -> \(.service)"'
  if confirm "Regenerate the default ingress and submit it?"; then
    local cfg; cfg=$(cfTunnelIngressBuild)
    cfTunnelConfigPut "$tid" "$cfg"
    ok "ingress reset to default"
  fi
}

# ============ SECTION 15 share-link renderer ============
__urlenc() {
  jq -rn --arg v "$1" '$v | @uri'
}
__sub_uuid()   { stateGet uuid; }
__sub_pbk()    { stateGet reality_pubkey; }
__sub_sid()    { stateGet reality_shortid; }
__sub_sni()    { stateGet reality_sni; }
__sub_pqv()    { stateGet reality_mldsa65_verify; }
__sub_token()  { stateGet sub_token; }
__sub_rhost()  { printf '%s.%s' "$SUB_R"   "$ROOT_DOMAIN"; }
__sub_cdnhost(){ printf '%s.%s' "$SUB_CDN" "$ROOT_DOMAIN"; }
__sub_cdnserver() {
  local ip enabled
  enabled=$(stateGet cfst_enabled); enabled="${enabled:-false}"
  ip=$(stateGet cfst_best_ip)
  if [[ "$enabled" == "true" && -n "$ip" ]] && validIpLiteral "$ip"; then
    printf '%s' "$ip"
  else
    __sub_cdnhost
  fi
}

__reality_qs() {
  local sni="$1"
  local pbk; pbk=$(__sub_pbk)
  local sid; sid=$(__sub_sid)
  local mldsa; mldsa=$(stateGet reality_mldsa65_enabled)
  local pqv; pqv=$(__sub_pqv)
  local q="security=reality&pbk=${pbk}&sni=${sni}&sid=${sid}&fp=chrome"
  if [[ "$mldsa" == "true" && -n "$pqv" ]]; then
    q="${q}&pqv=${pqv}"
  fi
  printf '%s' "$q"
}

# 1) R-VLESS-Vision
link_RVlessVision() {
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_rhost)
  local port="${PROTO_PORT[R-VLESS-Vision]}"
  local sni; sni=$(__sub_sni)
  local qs; qs=$(__reality_qs "$sni")
  printf 'vless://%s@%s:%s?%s&type=tcp&flow=xtls-rprx-vision&encryption=none#%s' \
    "$uuid" "$host" "$port" "$qs" "$(__urlenc "R-VLESS-Vision")"
}

# 2) R-VLESS-XHTTP
link_RVlessXHTTP() {
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_rhost)
  local port="${PROTO_PORT[R-VLESS-XHTTP]}"
  local sni; sni=$(__sub_sni)
  local path; path=$(stateGet xhttp_path)
  [[ -n "$path" ]] || path="/xh"
  local qs; qs=$(__reality_qs "$sni")
  printf 'vless://%s@%s:%s?%s&type=xhttp&path=%s&mode=auto&encryption=none#%s' \
    "$uuid" "$host" "$port" "$qs" "$(__urlenc "$path")" "$(__urlenc "R-VLESS-XHTTP")"
}

# 3) R-VLESS-gRPC
link_RVlessGRPC() {
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_rhost)
  local port="${PROTO_PORT[R-VLESS-gRPC]}"
  local sni; sni=$(__sub_sni)
  local service; service=$(stateGet grpc_service_name)
  [[ -n "$service" ]] || service="grpc"
  local qs; qs=$(__reality_qs "$sni")
  printf 'vless://%s@%s:%s?%s&type=grpc&serviceName=%s&encryption=none#%s' \
    "$uuid" "$host" "$port" "$qs" "$(__urlenc "$service")" "$(__urlenc "R-VLESS-gRPC")"
}

# 4) C-VLESS-XHTTP
link_CVlessXHTTP() {
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_cdnserver)
  local cdn; cdn=$(__sub_cdnhost)
  local p; p=$(__urlenc "$(cdnPath C-VLESS-XHTTP)")
  printf 'vless://%s@%s:443?security=tls&sni=%s&type=xhttp&host=%s&path=%s&mode=auto&alpn=h3&encryption=none#%s' \
    "$uuid" "$host" "$cdn" "$cdn" "$p" "$(__urlenc "C-VLESS-XHTTP")"
}

# 5) C-VLESS-WS
link_CVlessWS() {
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_cdnserver)
  local cdn; cdn=$(__sub_cdnhost)
  local p; p=$(__urlenc "$(cdnPath C-VLESS-WS)")
  printf 'vless://%s@%s:443?security=tls&sni=%s&type=ws&host=%s&path=%s&encryption=none#%s' \
    "$uuid" "$host" "$cdn" "$cdn" "$p" "$(__urlenc "C-VLESS-WS")"
}

# 6) C-Trojan-WS
link_CTrojanWS() {
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_cdnserver)
  local cdn; cdn=$(__sub_cdnhost)
  local p; p=$(__urlenc "$(cdnPath C-Trojan-WS)")
  printf 'trojan://%s@%s:443?security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
    "$uuid" "$host" "$cdn" "$cdn" "$p" "$(__urlenc "C-Trojan-WS")"
}

# 7) C-VMess-WS
link_CVmessWS() {
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_cdnserver)
  local cdn; cdn=$(__sub_cdnhost)
  local path; path=$(cdnPath C-VMess-WS)
  local name="C-VMess-WS"
  local b
  b=$(jq -n --arg v "2" --arg ps "$name" --arg add "$host" --arg port "443" \
            --arg id "$uuid" --arg aid "0" --arg net "ws" \
            --arg type "none" --arg host "$cdn" --arg path "$path" \
            --arg tls "tls" --arg sni "$cdn" \
        '{v:$v,ps:$ps,add:$add,port:$port,id:$id,aid:$aid,scy:"auto",net:$net,type:$type,host:$host,path:$path,tls:$tls,sni:$sni}' \
        | base64 -w0)
  printf 'vmess://%s' "$b"
}

# 8) C-VLESS-HTTPUpgrade
link_CVlessHTTPU() {
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_cdnserver)
  local cdn; cdn=$(__sub_cdnhost)
  local p; p=$(__urlenc "$(cdnPath C-VLESS-HTTPUpgrade)")
  printf 'vless://%s@%s:443?security=tls&sni=%s&type=httpupgrade&host=%s&path=%s&encryption=none#%s' \
    "$uuid" "$host" "$cdn" "$cdn" "$p" "$(__urlenc "C-VLESS-HTTPUpgrade")"
}

# 8) U-Hysteria2
link_UHysteria2() {
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_rhost)
  local port="${PROTO_PORT[U-Hysteria2]}"
  local ports; ports=$(hopClientPorts "U-Hysteria2")
  local obfs; obfs=$(stateGet hy2_obfs_password)
  printf 'hysteria2://%s@%s:%s?sni=%s&mport=%s&obfs=salamander&obfs-password=%s&alpn=h3#%s' \
    "$uuid" "$host" "$port" "$host" "$(__urlenc "$ports")" "$(__urlenc "$obfs")" "$(__urlenc "U-Hysteria2")"
}

# 9) U-TUIC-v5
link_UTuicV5() {
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_rhost)
  local port="${PROTO_PORT[U-TUIC-v5]}"
  local pwd; pwd=$(stateGet tuic_password)
  local ports; ports=$(hopClientPorts "U-TUIC-v5")
  printf 'tuic://%s:%s@%s:%s?sni=%s&mport=%s&congestion_control=bbr&alpn=h3#%s' \
    "$uuid" "$pwd" "$host" "$port" "$host" "$(__urlenc "$ports")" "$(__urlenc "U-TUIC-v5")"
}

# 10) D-AnyTLS
link_DAnyTLS() {
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_rhost)
  local port="${PROTO_PORT[D-AnyTLS]}"
  printf 'anytls://%s@%s:%s?sni=%s#%s' \
    "$uuid" "$host" "$port" "$host" "$(__urlenc "D-AnyTLS")"
}

# 11) D-NaiveProxy
link_DNaive() {
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_rhost)
  local port="${PROTO_PORT[D-NaiveProxy]}"
  printf 'naive+https://root:%s@%s:%s#%s' \
    "$uuid" "$host" "$port" "$(__urlenc "D-NaiveProxy")"
}

# 12) D-ShadowTLS-SS
link_DShadowTLSSS() {
  local host; host=$(__sub_rhost)
  local port="${PROTO_PORT[D-ShadowTLS-SS]}"
  local sni; sni=$(__sub_sni)
  local method; method=$(stateGet shadowtls_ss_method)
  local ss_pwd; ss_pwd=$(stateGet shadowtls_ss_password)
  local st_pwd; st_pwd=$(stateGet shadowtls_password)
  local plugin user_b64
  user_b64=$(printf '%s' "${method}:${ss_pwd}" | base64 -w0 | tr -d '=')
  plugin="shadow-tls;host=${sni};password=${st_pwd};version=3"
  printf 'ss://%s@%s:%s?plugin=%s#%s' \
    "$user_b64" "$host" "$port" "$(__urlenc "$plugin")" "$(__urlenc "D-ShadowTLS-SS")"
}

linkRenderersSelfCheck() {
  local tag fn
  for tag in "${PROTO_TAGS[@]}"; do
    fn="${PROTO_SCHEME[$tag]}"
    declare -F "$fn" >/dev/null || die "share-link renderer missing: $fn (tag=$tag)"
  done
}

# ============ SECTION 16 subscription generation ============
hopRangeDash() {
  local hop=$1
  printf '%s' "${hop/:/-}"
}

hopClientPorts() {
  local tag=$1
  local main="${PROTO_PORT[$tag]}"
  local hop="${PROTO_HOP[$tag]}"
  if [[ -n "$hop" ]]; then
    printf '%s,%s' "$main" "$(hopRangeDash "$hop")"
  else
    printf '%s' "$main"
  fi
}

subToken() {
  local cur; cur=$(stateGet sub_token)
  if [[ -n "$cur" ]]; then
    printf '%s' "$cur"; return 0
  fi
  local t; t=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
  stateSet sub_token "$t"
  printf '%s' "$t"
}

# generateDefaultSub: base64 aggregate subscription
generateDefaultSub() {
  loadState
  stateEnsureProtocolSecrets
  protoApplyOverride
  local lines=() tag fn
  for tag in "${PROTO_TAGS[@]}"; do
    protoIsDisabled "$tag" && continue
    fn="${PROTO_SCHEME[$tag]}"
    lines+=("$($fn)")
  done
  printf '%s\n' "${lines[@]}" | base64 -w0
}

# mihomo_* helper functions: output a single YAML block for mihomo proxies
__mihomo_yaml_common() {
  local tag=$1
  printf '  - name: "%s"\n' "$tag"
}

mihomoRealityVerifyBlock() {
  local indent="${1:-      }"
  local enabled; enabled=$(stateGet reality_mldsa65_enabled)
  local verify; verify=$(__sub_pqv)
  [[ "$enabled" == "true" && -n "$verify" ]] || return 0
  printf '%smldsa65-verify: %s\n' "$indent" "$verify"
}

mihomo_RVlessVision() {
  local tag="R-VLESS-Vision"
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_rhost)
  local port="${PROTO_PORT[$tag]}"
  local sni; sni=$(__sub_sni)
  local pbk; pbk=$(__sub_pbk)
  local sid; sid=$(__sub_sid)
  cat <<EOF
  - name: "${tag}"
    type: vless
    server: ${host}
    port: ${port}
    uuid: ${uuid}
    network: tcp
    tls: true
    flow: xtls-rprx-vision
    servername: ${sni}
    reality-opts:
      public-key: ${pbk}
      short-id: ${sid}
$(mihomoRealityVerifyBlock "      ")
    client-fingerprint: chrome
EOF
}

mihomo_RVlessXHTTP() {
  local tag="R-VLESS-XHTTP"
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_rhost)
  local port="${PROTO_PORT[$tag]}"
  local sni; sni=$(__sub_sni)
  local pbk; pbk=$(__sub_pbk)
  local sid; sid=$(__sub_sid)
  local path; path=$(stateGet xhttp_path)
  [[ -n "$path" ]] || path="/xh"
  cat <<EOF
  - name: "${tag}"
    type: vless
    server: ${host}
    port: ${port}
    uuid: ${uuid}
    network: xhttp
    xhttp-opts:
      path: "${path}"
      mode: auto
    tls: true
    servername: ${sni}
    reality-opts:
      public-key: ${pbk}
      short-id: ${sid}
$(mihomoRealityVerifyBlock "      ")
    client-fingerprint: chrome
EOF
}

mihomo_RVlessGRPC() {
  local tag="R-VLESS-gRPC"
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_rhost)
  local port="${PROTO_PORT[$tag]}"
  local sni; sni=$(__sub_sni)
  local pbk; pbk=$(__sub_pbk)
  local sid; sid=$(__sub_sid)
  local service; service=$(stateGet grpc_service_name)
  [[ -n "$service" ]] || service="grpc"
  cat <<EOF
  - name: "${tag}"
    type: vless
    server: ${host}
    port: ${port}
    uuid: ${uuid}
    network: grpc
    grpc-opts:
      grpc-service-name: ${service}
    tls: true
    servername: ${sni}
    reality-opts:
      public-key: ${pbk}
      short-id: ${sid}
$(mihomoRealityVerifyBlock "      ")
    client-fingerprint: chrome
EOF
}

mihomo_CVlessXHTTP() {
  local tag="C-VLESS-XHTTP"
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_cdnserver)
  local cdn; cdn=$(__sub_cdnhost)
  local path; path=$(cdnPath "$tag")
  cat <<EOF
  - name: "${tag}"
    type: vless
    server: ${host}
    port: 443
    uuid: ${uuid}
    tls: true
    network: xhttp
    servername: ${cdn}
    alpn:
      - h3
    xhttp-opts:
      path: "${path}"
      mode: auto
    headers:
      Host: ${cdn}
EOF
}

mihomo_CVlessWS() {
  local tag="C-VLESS-WS"
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_cdnserver)
  local cdn; cdn=$(__sub_cdnhost)
  local path; path=$(cdnPath "$tag")
  cat <<EOF
  - name: "${tag}"
    type: vless
    server: ${host}
    port: 443
    uuid: ${uuid}
    tls: true
    network: ws
    servername: ${cdn}
    ws-opts:
      path: ${path}
      headers:
        Host: ${cdn}
EOF
}

mihomo_CTrojanWS() {
  local tag="C-Trojan-WS"
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_cdnserver)
  local cdn; cdn=$(__sub_cdnhost)
  local path; path=$(cdnPath "$tag")
  cat <<EOF
  - name: "${tag}"
    type: trojan
    server: ${host}
    port: 443
    password: ${uuid}
    sni: ${cdn}
    network: ws
    ws-opts:
      path: ${path}
      headers:
        Host: ${cdn}
EOF
}

mihomo_CVmessWS() {
  local tag="C-VMess-WS"
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_cdnserver)
  local cdn; cdn=$(__sub_cdnhost)
  local path; path=$(cdnPath "$tag")
  cat <<EOF
  - name: "${tag}"
    type: vmess
    server: ${host}
    port: 443
    uuid: ${uuid}
    alterId: 0
    cipher: auto
    tls: true
    servername: ${cdn}
    network: ws
    ws-opts:
      path: ${path}
      headers:
        Host: ${cdn}
EOF
}

mihomo_CVlessHTTPU() {
  local tag="C-VLESS-HTTPUpgrade"
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_cdnserver)
  local cdn; cdn=$(__sub_cdnhost)
  local path; path=$(cdnPath "$tag")
  cat <<EOF
  - name: "${tag}"
    type: vless
    server: ${host}
    port: 443
    uuid: ${uuid}
    tls: true
    network: ws
    servername: ${cdn}
    ws-opts:
      path: ${path}
      headers:
        Host: ${cdn}
      v2ray-http-upgrade: true
EOF
}

mihomo_UHysteria2() {
  local tag="U-Hysteria2"
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_rhost)
  local port="${PROTO_PORT[$tag]}"
  local ports; ports=$(hopClientPorts "$tag")
  local obfs; obfs=$(stateGet hy2_obfs_password)
  cat <<EOF
  - name: "${tag}"
    type: hysteria2
    server: ${host}
    port: ${port}
    password: ${uuid}
    sni: ${host}
    obfs: salamander
    obfs-password: ${obfs}
    alpn:
      - h3
    ports: "${ports}"
EOF
}

mihomo_UTuicV5() {
  local tag="U-TUIC-v5"
  local uuid; uuid=$(__sub_uuid)
  local pwd; pwd=$(stateGet tuic_password)
  local host; host=$(__sub_rhost)
  local port="${PROTO_PORT[$tag]}"
  local ports; ports=$(hopClientPorts "$tag")
  cat <<EOF
  - name: "${tag}"
    type: tuic
    server: ${host}
    port: ${port}
    uuid: ${uuid}
    password: ${pwd}
    sni: ${host}
    ports: "${ports}"
    congestion-controller: bbr
    udp-relay-mode: native
    alpn:
      - h3
EOF
}

mihomo_DNaive() {
  local tag="D-NaiveProxy"
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_rhost)
  local port="${PROTO_PORT[$tag]}"
  cat <<EOF
  - name: "${tag}"
    type: naive
    server: ${host}
    port: ${port}
    username: root
    password: ${uuid}
    tls: true
    sni: ${host}
EOF
}

mihomo_DAnyTLS() {
  local tag="D-AnyTLS"
  local uuid; uuid=$(__sub_uuid)
  local host; host=$(__sub_rhost)
  local port="${PROTO_PORT[$tag]}"
  cat <<EOF
  - name: "${tag}"
    type: anytls
    server: ${host}
    port: ${port}
    password: ${uuid}
    sni: ${host}
EOF
}

mihomo_DShadowTLSSS() {
  local tag="D-ShadowTLS-SS"
  local method; method=$(stateGet shadowtls_ss_method)
  local ss_pwd; ss_pwd=$(stateGet shadowtls_ss_password)
  local st_pwd; st_pwd=$(stateGet shadowtls_password)
  local host; host=$(__sub_rhost)
  local port="${PROTO_PORT[$tag]}"
  local sni; sni=$(__sub_sni)
  cat <<EOF
  - name: "${tag}"
    type: ss
    server: ${host}
    port: ${port}
    cipher: ${method}
    password: ${ss_pwd}
    plugin: shadow-tls
    client-fingerprint: chrome
    plugin-opts:
      host: ${sni}
      password: ${st_pwd}
      version: 3
EOF
}

mihomoProxy() {
  local tag=$1
  # Hard skip at the top: mihomo does not include NaiveProxy by default
  if [[ "$tag" == "D-NaiveProxy" ]]; then
    local incl; incl=$(stateGet sub_include_naive_mihomo)
    [[ "$incl" == "true" ]] || return 0
  fi
  case "$tag" in
    R-VLESS-Vision)      mihomo_RVlessVision ;;
    R-VLESS-XHTTP)       mihomo_RVlessXHTTP  ;;
    R-VLESS-gRPC)        mihomo_RVlessGRPC   ;;
    C-VLESS-XHTTP)       mihomo_CVlessXHTTP  ;;
    C-VLESS-WS)          mihomo_CVlessWS     ;;
    C-Trojan-WS)         mihomo_CTrojanWS    ;;
    C-VMess-WS)          mihomo_CVmessWS     ;;
    C-VLESS-HTTPUpgrade) mihomo_CVlessHTTPU  ;;
    U-Hysteria2)         mihomo_UHysteria2   ;;
    U-TUIC-v5)           mihomo_UTuicV5      ;;
    D-AnyTLS)            mihomo_DAnyTLS      ;;
    D-NaiveProxy)        mihomo_DNaive       ;;
    D-ShadowTLS-SS)      mihomo_DShadowTLSSS ;;
  esac
}

generateClashMetaSub() {
  loadState; stateEnsureProtocolSecrets; protoApplyOverride
  printf '# janus mihomo proxies-only (v%s)\nproxies:\n' "$VERSION"
  local tag
  for tag in "${PROTO_TAGS[@]}"; do
    protoIsDisabled "$tag" && continue
    mihomoProxy "$tag"
  done
}

mihomoProxyTagEnabled() {
  local tag=$1
  protoIsDisabled "$tag" && return 1
  if [[ "$tag" == "D-NaiveProxy" ]]; then
    [[ "$(stateGet sub_include_naive_mihomo)" == "true" ]] || return 1
  fi
  return 0
}

mihomoPrintProxyList() {
  local tag
  for tag in "${PROTO_TAGS[@]}"; do
    mihomoProxyTagEnabled "$tag" || continue
    printf '      - "%s"\n' "$tag"
  done
}

generateMihomoFullSub() {
  loadState; stateEnsureProtocolSecrets; protoApplyOverride
  local tag enabled_count=0
  for tag in "${PROTO_TAGS[@]}"; do
    if mihomoProxyTagEnabled "$tag"; then
      (( enabled_count += 1 ))
    fi
  done
  if (( enabled_count == 0 )); then
    warn "mihomo-full needs at least one enabled Mihomo proxy"
    return 1
  fi
  cat <<EOF
# janus mihomo full config (inline)
mixed-port: 7890
mode: rule
log-level: info
allow-lan: false
tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver:
    - 1.1.1.1
    - 8.8.8.8
  nameserver:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
proxies:
EOF
  for tag in "${PROTO_TAGS[@]}"; do
    mihomoProxyTagEnabled "$tag" || continue
    mihomoProxy "$tag"
  done
  cat <<EOF
proxy-groups:
  - name: AUTO
    type: url-test
    proxies:
EOF
  mihomoPrintProxyList
  cat <<EOF
    url: http://www.gstatic.com/generate_204
    interval: 300
  - name: PROXY
    type: select
    proxies:
      - AUTO
EOF
  mihomoPrintProxyList
  cat <<EOF
rule-providers: {}
rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF
}

# generateSboxSub: output sing-box outbound JSON(outbounds array only)
generateSboxSub() {
  loadState; stateEnsureProtocolSecrets; protoApplyOverride
  local uuid; uuid=$(__sub_uuid)
  local rhost; rhost=$(__sub_rhost)
  local cdn;   cdn=$(__sub_cdnhost)
  local cdn_server; cdn_server=$(__sub_cdnserver)
  local sni;   sni=$(__sub_sni)
  local pbk;   pbk=$(__sub_pbk)
  local sid;   sid=$(__sub_sid)
  local pqv;   pqv=$(__sub_pqv)
  local mldsa_enabled; mldsa_enabled=$(stateGet reality_mldsa65_enabled)
  local xhttp_path; xhttp_path=$(stateGet xhttp_path)
  local grpc_service; grpc_service=$(stateGet grpc_service_name)
  local hy2_obfs; hy2_obfs=$(stateGet hy2_obfs_password)
  local tuic_pwd; tuic_pwd=$(stateGet tuic_password)
  local st_pwd; st_pwd=$(stateGet shadowtls_password)
  local st_ss_method; st_ss_method=$(stateGet shadowtls_ss_method)
  local st_ss_pwd; st_ss_pwd=$(stateGet shadowtls_ss_password)
  local h2_hop; h2_hop="${PROTO_HOP[U-Hysteria2]}"
  local enabled; enabled=$(protoEnabledJson)
  local tags_json; tags_json=$(printf '%s\n' "${PROTO_TAGS[@]}" | jq -R . | jq -sc .)

  jq -n \
    --argjson tags "$tags_json" \
    --arg u "$uuid" --arg rhost "$rhost" --arg cdn "$cdn" --arg cdn_server "$cdn_server" \
    --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg pqv "$pqv" --argjson mldsa_enabled "${mldsa_enabled:-false}" \
    --arg xhttp_path "$xhttp_path" --arg grpc_service "$grpc_service" \
    --arg hy2_obfs "$hy2_obfs" --arg tuic_pwd "$tuic_pwd" \
    --arg st_pwd "$st_pwd" --arg st_ss_method "$st_ss_method" --arg st_ss_pwd "$st_ss_pwd" \
    --arg h2_hop "$h2_hop" \
    --arg c_xhttp "$(cdnPath C-VLESS-XHTTP)" \
    --arg c_vless_ws "$(cdnPath C-VLESS-WS)" \
    --arg c_trojan_ws "$(cdnPath C-Trojan-WS)" \
    --arg c_vmess_ws "$(cdnPath C-VMess-WS)" \
    --arg c_httpu "$(cdnPath C-VLESS-HTTPUpgrade)" \
    --argjson enabled "$enabled" \
    --argjson p_vision "${PROTO_PORT[R-VLESS-Vision]}" \
    --argjson p_xhttp  "${PROTO_PORT[R-VLESS-XHTTP]}" \
    --argjson p_grpc   "${PROTO_PORT[R-VLESS-gRPC]}" \
    --argjson p_h2     "${PROTO_PORT[U-Hysteria2]}" \
    --argjson p_tuic   "${PROTO_PORT[U-TUIC-v5]}" \
    --argjson p_anytls "${PROTO_PORT[D-AnyTLS]}" \
    --argjson p_naive  "${PROTO_PORT[D-NaiveProxy]}" \
    --argjson p_stls   "${PROTO_PORT[D-ShadowTLS-SS]}" '
    { outbounds: [
        { type:"vless", tag:"R-VLESS-Vision", server:$rhost, server_port:$p_vision,
          uuid:$u, flow:"xtls-rprx-vision",
          tls:{enabled:true, server_name:$sni,
               reality:({enabled:true, public_key:$pbk, short_id:$sid} + (if $mldsa_enabled and ($pqv|length>0) then {mldsa65_verify:$pqv} else {} end)),
               utls:{enabled:true, fingerprint:"chrome"}} },
        { type:"vless", tag:"R-VLESS-XHTTP", server:$rhost, server_port:$p_xhttp,
          uuid:$u, transport:{type:"http", path:$xhttp_path},
          tls:{enabled:true, server_name:$sni,
               reality:({enabled:true, public_key:$pbk, short_id:$sid} + (if $mldsa_enabled and ($pqv|length>0) then {mldsa65_verify:$pqv} else {} end)),
               utls:{enabled:true, fingerprint:"chrome"}} },
        { type:"vless", tag:"R-VLESS-gRPC", server:$rhost, server_port:$p_grpc,
          uuid:$u, transport:{type:"grpc", service_name:$grpc_service},
          tls:{enabled:true, server_name:$sni,
               reality:({enabled:true, public_key:$pbk, short_id:$sid} + (if $mldsa_enabled and ($pqv|length>0) then {mldsa65_verify:$pqv} else {} end)),
               utls:{enabled:true, fingerprint:"chrome"}} },
        { type:"vless", tag:"C-VLESS-XHTTP", server:$cdn_server, server_port:443,
          uuid:$u, transport:{type:"http", path:$c_xhttp},
          tls:{enabled:true, server_name:$cdn, alpn:["h3"]} },
        { type:"vless", tag:"C-VLESS-WS", server:$cdn_server, server_port:443,
          uuid:$u, transport:{type:"ws", path:$c_vless_ws, headers:{Host:$cdn}},
          tls:{enabled:true, server_name:$cdn} },
        { type:"trojan", tag:"C-Trojan-WS", server:$cdn_server, server_port:443,
          password:$u, transport:{type:"ws", path:$c_trojan_ws, headers:{Host:$cdn}},
          tls:{enabled:true, server_name:$cdn} },
        { type:"vmess", tag:"C-VMess-WS", server:$cdn_server, server_port:443,
          uuid:$u, alter_id:0, security:"auto",
          transport:{type:"ws", path:$c_vmess_ws, headers:{Host:$cdn}},
          tls:{enabled:true, server_name:$cdn} },
        { type:"vless", tag:"C-VLESS-HTTPUpgrade", server:$cdn_server, server_port:443,
          uuid:$u, transport:{type:"httpupgrade", path:$c_httpu, headers:{Host:$cdn}},
          tls:{enabled:true, server_name:$cdn} },
        { type:"hysteria2", tag:"U-Hysteria2", server:$rhost, server_port:$p_h2,
          server_ports:[$h2_hop],
          password:$u, obfs:{type:"salamander", password:$hy2_obfs},
          tls:{enabled:true, server_name:$rhost, alpn:["h3"]} },
        { type:"tuic", tag:"U-TUIC-v5", server:$rhost, server_port:$p_tuic,
          uuid:$u, password:$tuic_pwd, congestion_control:"bbr",
          tls:{enabled:true, server_name:$rhost, alpn:["h3"]} },
        { type:"anytls", tag:"D-AnyTLS", server:$rhost, server_port:$p_anytls,
          password:$u, tls:{enabled:true, server_name:$rhost} },
        { type:"naive", tag:"D-NaiveProxy", server:$rhost, server_port:$p_naive,
          username:"root", password:$u, tls:{enabled:true, server_name:$rhost} },
        { type:"shadowsocks", tag:"D-ShadowTLS-SS", server:"127.0.0.1", server_port:10453,
          method:$st_ss_method, password:$st_ss_pwd,
          detour:"D-ShadowTLS-SS-shadowtls" },
        { type:"shadowtls", tag:"D-ShadowTLS-SS-shadowtls", server:$rhost, server_port:$p_stls,
          version:3, password:$st_pwd,
          tls:{enabled:true, server_name:$sni} },
        { type:"direct", tag:"direct" },
        { type:"block",  tag:"block" }
      ]
    } | .outbounds as $all
      | .outbounds =
          ( [ $tags[]
              | . as $t
              | select(($enabled | index($t)) != null)
              | $all[] | select(.tag == $t) ]
            + ( $all
                | map(select(.tag == "D-ShadowTLS-SS-shadowtls"))
                | map(select( ($enabled | index("D-ShadowTLS-SS")) != null )) )
            + [ $all[] | select(.tag == "direct" or .tag == "block") ] )'
}

# subPublish: write <token>/v<ts>/{default,mihomo,sbox,mihomo-full} plus the latest symlink
subPublish() {
  local token=$1
  local default=$2 mihomo=$3 sbox=$4 mihomo_full=$5
  mkdir -p "${WEBROOT}/${token}"
  local ts; ts=$(date +%Y%m%d%H%M%S)
  local d="${WEBROOT}/${token}/v${ts}"
  mkdir -p "$d"
  printf '%s' "$default"     > "${d}/default"
  printf '%s' "$mihomo"      > "${d}/mihomo"
  printf '%s' "$sbox"        > "${d}/sbox"
  printf '%s' "$mihomo_full" > "${d}/mihomo-full"
  chmod 644 "${d}"/*
  ln -sfn "v${ts}" "${WEBROOT}/${token}/latest"
  # Keep the latest five versions
  local olds
  olds=$(ls -1dt "${WEBROOT}/${token}"/v* 2>/dev/null | tail -n +6 || true)
  if [[ -n "$olds" ]]; then
    xargs rm -rf <<<"$olds"
  fi
  ok "Subscription published"
}

subRegenAllCore() {
  loadState
  local token; token=$(subToken)
  local d m s mf failed=0
  if ! d=$(generateDefaultSub); then
    warn "default subscription generation failed"
    failed=1
  fi
  if ! m=$(generateClashMetaSub); then
    warn "mihomo subscription generation failed"
    failed=1
  fi
  if ! s=$(generateSboxSub); then
    warn "sing-box subscription generation failed"
    failed=1
  fi
  if ! mf=$(generateMihomoFullSub); then
    warn "mihomo-full subscription generation failed"
    failed=1
  fi
  if (( failed )); then
    stateSetJson alert '"sub_regen_partial_fail"'
    warn "subscription generation incomplete, latest remains on the previous version"
    return 1
  fi
  stateSetJson alert 'null'
  subPublish "$token" "$d" "$m" "$s" "$mf"
}

subRegenAll() {
  banner "Regenerate subscriptions"
  subRegenAllCore || die "subscription generation failed; latest was not switched"
  subShow
}

subRotateToken() {
  protoRekeyUUID
}

subShow() {
  banner "Subscription information"
  loadState
  if [[ -z "${ROOT_DOMAIN:-}" ]]; then
    ROOT_DOMAIN=$(stateGet domain)
    export ROOT_DOMAIN
  fi
  [[ -n "${ROOT_DOMAIN:-}" ]] || die "state.domain is missing; run environment initialization first"

  if ! have qrencode; then
    warn "qrencode is missing; installing required dependencies before rendering QR codes"
    installDeps
  fi

  local sub_host="${SUB_SUB}.${ROOT_DOMAIN}"
  local tok; tok=$(stateGet sub_token)
  [[ -n "$tok" ]] || die "state.sub_token is missing; regenerate subscriptions first"
  local base="https://${sub_host}/${tok}/latest"
  local names=(default mihomo mihomo-full sbox)
  local labels=("default subscription" "mihomo provider" "mihomo full config" "sing-box JSON")
  local i url
  for i in "${!names[@]}"; do
    url="${base}/${names[$i]}"
    printf '%-18s %s\n' "${labels[$i]}:" "$url"
  done
  echo
  if have qrencode; then
    for i in "${!names[@]}"; do
      url="${base}/${names[$i]}"
      echo "${labels[$i]} QR code: "
      qrencode -t ANSIUTF8 -m 1 "$url" || warn "QR rendering failed for ${labels[$i]}"
      echo
    done
  else
    warn "qrencode is still unavailable; URLs were printed without QR codes"
  fi
}

subDumpMihomo()     { generateClashMetaSub; }
subDumpSbox()       { generateSboxSub; }
subDumpDefault()    {
  local raw; raw=$(generateDefaultSub) || return $?
  printf '%s\n' "$raw"
  printf -- '--- base64 decoded ---\n'
  printf '%s' "$raw" | base64 -d 2>/dev/null || true
  printf '\n'
}
subDumpMihomoFull() { generateMihomoFullSub; }

subExportCurrent() {
  loadState
  local tok; tok=$(stateGet sub_token)
  [[ -n "$tok" ]] || die "sub_token not initialized"
  local src="${WEBROOT}/${tok}/latest"
  [[ -d "$src" ]] || { subRegenAllCore; }
  local out
  out="/tmp/janus-current-config-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$out"
  cp -a "${WEBROOT}/${tok}/latest/"* "$out"/
  cat > "${out}/README.txt" <<EOF
janus current configuration export
domain=${ROOT_DOMAIN}
generated_at=$(date -Is)
formats=default,mihomo,mihomo-full,sbox
EOF
  tar -czf "${out}.tar.gz" -C "$out" .
  rm -rf "$out"
  ok "exported: ${out}.tar.gz"
}

subServeOne() {
  loadState
  local method path proto
  IFS=' ' read -r method path proto || return 0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && break
  done

  local token; token=$(stateGet sub_token)
  path="${path%%\?*}"
  local rel="${path#/}"
  local expected_prefix="${token}/latest/"
  local fmt="${rel#"${expected_prefix}"}"
  local file ctype filename add_update_header=0

  if [[ -z "$token" || "$rel" == "$fmt" || "$fmt" == *"/"* ]]; then
    subServeNotFound
    return 0
  fi

  case "$fmt" in
    default)
      file="${WEBROOT}/${token}/latest/default"; ctype="text/plain; charset=utf-8"; filename="janus-default.txt" ;;
    mihomo)
      file="${WEBROOT}/${token}/latest/mihomo"; ctype="text/yaml; charset=utf-8"; filename="janus-mihomo.yaml"; add_update_header=1 ;;
    sbox)
      file="${WEBROOT}/${token}/latest/sbox"; ctype="application/json; charset=utf-8"; filename="janus-sing-box.json" ;;
    mihomo-full)
      file="${WEBROOT}/${token}/latest/mihomo-full"; ctype="text/yaml; charset=utf-8"; filename="janus-mihomo-full.yaml"; add_update_header=1 ;;
    *)
      subServeNotFound; return 0 ;;
  esac

  if [[ "$method" != "GET" && "$method" != "HEAD" ]] || [[ ! -f "$file" ]]; then
    subServeNotFound
    return 0
  fi

  local len; len=$(wc -c < "$file" | tr -d ' ')
  printf 'HTTP/1.1 200 OK\r\n'
  printf 'Content-Type: %s\r\n' "$ctype"
  printf 'Content-Length: %s\r\n' "$len"
  printf 'Cache-Control: no-store\r\n'
  printf 'Content-Disposition: attachment; filename="%s"\r\n' "$filename"
  if (( add_update_header )); then
    printf 'profile-update-interval: 12\r\n'
  fi
  printf '\r\n'
  [[ "$method" == "HEAD" ]] || cat "$file"
}

subServeNotFound() {
  local body='404 not found'
  printf 'HTTP/1.1 404 Not Found\r\n'
  printf 'Content-Type: text/plain; charset=utf-8\r\n'
  printf 'Content-Length: %s\r\n' "${#body}"
  printf 'Cache-Control: no-store\r\n'
  printf '\r\n%s' "$body"
}

subChangePort() {
  banner "Change the subscription responder port"
  local cur new; cur=$(stateGet sub_darkhttpd_port)
  prompt new "New port" "$cur"
  [[ -n "$new" ]] || return 0
  stateSet sub_darkhttpd_port "$new"
  unitSub
  systemctl daemon-reload
  systemctl restart "$UNIT_SUB"
  cfTunnelConfigPut "$(stateGet cf_tunnel_id)" "$(cfTunnelIngressBuild)"
  ok "Subscription responder port updated to $new"
}

advToggleNaiveInMihomo() {
  loadState
  local cur; cur=$(stateGet sub_include_naive_mihomo)
  local nv="true"
  [[ "$cur" == "true" ]] && nv="false"
  stateSet sub_include_naive_mihomo "$nv"
  subRegenAllCore
  ok "mihomo includes D-NaiveProxy: $nv"
}

moduleInstallSubServer() {
  banner "Install subscription service(built-in HTTP responder)"
  depsAllInstalled || installDeps
  need socat
  mkdir -p "$WEBROOT"; chmod 755 "$WEBROOT"

  # Keep the responder target in sync with the currently running installer.
  # This matters when a previous broken /etc/janus/install.sh already exists.
  local self="${BASH_SOURCE[0]:-}"
  if [[ -f "$self" ]]; then
    local self_real dest_real
    self_real=$(readlink -f "$self" 2>/dev/null || printf '%s' "$self")
    dest_real=$(readlink -f "$INSTALL_SH_DEST" 2>/dev/null || printf '%s' "$INSTALL_SH_DEST")
    if [[ "$self_real" == "$dest_real" ]]; then
      chmod 0755 "$INSTALL_SH_DEST"
    else
      install -m 0755 "$self" "$INSTALL_SH_DEST"
    fi
  elif [[ ! -x "$INSTALL_SH_DEST" ]]; then
    upgradeSelf
  fi

  [[ -x "$INSTALL_SH_DEST" ]] || die "failed to install ${INSTALL_SH_DEST}"
  unitSub
  systemctl daemon-reload
  systemctl enable --now "$UNIT_SUB" >/dev/null
  systemctl is-active --quiet "$UNIT_SUB" || die "${UNIT_SUB} failed to start"
  ok "Subscription service started"
}

# ============ SECTION 17 CLI shim installation ============
moduleInstallCLI() {
  banner "Install/repair janus CLI"
  mkdir -p "$WORKDIR"
  # Copy the current install.sh to the fixed path (BASH_SOURCE may be empty when invoked via curl|bash)
  local self="${BASH_SOURCE[0]:-}"
  if [[ -f "$self" ]]; then
    # If it is already the target file, install fails with "same file"; skip copy and only refresh permissions.
    local self_real dest_real
    self_real=$(readlink -f "$self" 2>/dev/null || printf '%s' "$self")
    dest_real=$(readlink -f "$INSTALL_SH_DEST" 2>/dev/null || printf '%s' "$INSTALL_SH_DEST")
    if [[ "$self_real" == "$dest_real" ]]; then
      chmod 0755 "$INSTALL_SH_DEST"
    else
      install -m 0755 "$self" "$INSTALL_SH_DEST"
    fi
  else
    upgradeSelf
  fi
  cat > "$CLI_PATH" <<EOF
#!/usr/bin/env bash
exec ${INSTALL_SH_DEST} "\$@"
EOF
  chmod 0755 "$CLI_PATH"
  ok "CLI installed: $CLI_PATH"
  log "quickInstall already runs this step by default; this action will rewrite ${INSTALL_SH_DEST} and ${CLI_PATH}"
}

# ============ SECTION 18 menu system ============
renderStateHeader() {
  local state_ok=1
  loadState || state_ok=0
  local d="" sni="" alert="" cfst_ip=""
  if (( state_ok )); then
    d=$(stateGet domain)
    sni=$(stateGet reality_sni)
    alert=$(stateGet alert)
    cfst_ip=$(stateGet cfst_best_ip)
  fi

  local cert_days="-"
  if [[ -s "$CERT_FULLCHAIN" ]]; then
    local end_ts now_ts
    end_ts=$(date -d "$(openssl x509 -in "$CERT_FULLCHAIN" -noout -enddate 2>/dev/null | sed 's/notAfter=//')" +%s 2>/dev/null || echo 0)
    now_ts=$(date +%s)
    if (( end_ts > 0 )); then
      cert_days=$(( (end_ts - now_ts) / 86400 ))
    fi
  fi

  local title="janus v${VERSION}" width=58
  local pad=$(( (width - ${#title}) / 2 ))
  printf '\n%s\n' "$(__c "$CLR_BORDER" "==========================================================")"
  printf '%*s%s\n' "$pad" "" "$(__c "$CLR_INFO" "$title")"
  printf '%s\n' "$(__c "$CLR_BORDER" "==========================================================")"
  printf '  %s %s\n' "$(__c "$CLR_SECTION" "Domain:")" "${d:-not set}"
  printf '  %s %sd\n' "$(__c "$CLR_SECTION" "Certificate:")" "$cert_days"
  printf '  %s %s\n' "$(__c "$CLR_SECTION" "SNI:")" "${sni:-not set}"
  local cfst_enabled_v cfst_best_v
  if (( state_ok )); then
    cfst_enabled_v=$(stateGet cfst_enabled); cfst_enabled_v="${cfst_enabled_v:-false}"
  else
    cfst_enabled_v="unknown"
  fi
  if [[ "$cfst_enabled_v" == "true" && -n "$cfst_ip" ]]; then
    cfst_best_v="$cfst_ip"
  else
    cfst_best_v="N/A"
  fi
  printf '  %s enabled=%s best=%s\n' "$(__c "$CLR_SECTION" "CFST:")" "$cfst_enabled_v" "$cfst_best_v"
  if (( ! state_ok )); then
    warn "state.json is empty or corrupted; showing a degraded status header. Restore or repair state first."
  fi
  if [[ -n "$alert" && "$alert" != "null" ]]; then
    warn "Status alert: $alert"
  fi
}

# Main menu
mainMenu() {
  while :; do
    [[ -t 1 ]] && clear || true
    renderStateHeader
    menuLine "1) Quick install(one-click full flow)"
    menuLine "2) Initialization / module installation"
    menuLine "3) Protocol management"
    menuLine "4) Reality SNI management"
    menuLine "5) Cloudflare CDN / Tunnel / DNS"
    menuLine "6) Subscription management"
    menuLine "7) Service management"
    menuLine "8) Diagnostics and Status"
    menuLine "9) upgrade"
    menuLine "10) Backup and Restore"
    menuLine "11) Advanced / experimental"
    menuLine "0) Uninstall"
    menuLine "q) exit"
    local ch
    read -r -p "Select: " ch || true
    case "$ch" in
      1) menuInvoke quickInstall; menuPause ;;
      2) menuInit ;;
      3) menuProto ;;
      4) menuReality ;;
      5) menuCF ;;
      6) menuSub ;;
      7) menuSvc ;;
      8) menuDiag ;;
      9) menuUpgrade ;;
      10) menuBackup ;;
      11) menuAdvanced ;;
      0) menuInvoke doUninstall; menuPause ;;
      q|Q) break ;;
      *) warn "Invalid option";;
    esac
  done
}

menuInit() {
  while :; do
    cat <<'X'
[Initialization / module installation]
  1) System dependencies and kernel tuning
  2) Firewall
  3) Install Xray
  4) Install sing-box
  5) Install cloudflared
  6) Issue certificate
  7) Initialize state(UUID/short_id/sub_token/IP detection)
  8) Install subscription service
  9) Install/repair janus CLI
  0) Back
X
    local c; read -r -p "Select: " c || true
    case "$c" in
      1) menuInvoke moduleSysDeps; menuPause ;;
      2) menuInvoke moduleFirewall; menuPause ;;
      3) menuInvoke moduleInstallXray; menuPause ;;
      4) menuInvoke moduleInstallSbox; menuPause ;;
      5) menuInvoke moduleInstallCFD; menuPause ;;
      6) menuInvoke moduleAcme; menuPause ;;
      7) menuInvoke moduleInitState; menuPause ;;
      8) menuInvoke moduleInstallSubServer; menuPause ;;
      9) menuInvoke moduleInstallCLI; menuPause ;;
      0) return ;;
      *) warn "Invalid";;
    esac
  done
}

menuProto() {
  while :; do
    cat <<'X'
[Protocol management]
  1) List
  2) Enabled
  3) Disabled
  4) Change port
  5) Reset all defaults
  0) Back
X
    local c; read -r -p "Select: " c || true
    case "$c" in
      1) menuInvoke protoList; menuPause ;;
      2) menuInvoke protoEnable; menuPause ;;
      3) menuInvoke protoDisable; menuPause ;;
      4) menuInvoke protoChangePort; menuPause ;;
      5) menuInvoke protoResetAll; menuPause ;;
      0) return ;;
      *) warn "Invalid";;
    esac
  done
}

menuReality() {
  while :; do
    cat <<'X'
[Reality SNI]
  1) rotate immediately SNI
  2) Show status
  3) Set override
  4) Clear override
  5) RealiTLScanner candidate validation
  6) ML-DSA-65 toggle
  7) Show curated dictionary
  0) Back
  Tip: Reality reset Reality keys/short_id from the advanced menu
X
    local c; read -r -p "Select: " c || true
    case "$c" in
      1) menuInvoke sniRotateNow; menuPause ;;
      2) menuInvoke sniStatus; menuPause ;;
      3) menuInvoke sniSetOverride; menuPause ;;
      4) menuInvoke sniClearOverride; menuPause ;;
      5) menuInvoke sniScannerExtend; menuPause ;;
      6) menuInvoke realityToggleMldsa; menuPause ;;
      7) menuInvoke sniShowDict; menuPause ;;
      0) return ;;
      *) warn "Invalid";;
    esac
  done
}

menuCF() {
  while :; do
    cat <<'X'
[Cloudflare Tunnel & DNS]
  1) Update token
  2) Tunnel status
  3) Rebuild the Cloudflare CDN/Tunnel entry
  4) Show DNS
  5) Domain migration
  6) CFST status
  7) CFST Run speed test now
  8) CFST on/off
  9) Clear CFST preferred IP
  0) Back
X
    local c; read -r -p "Select: " c || true
    case "$c" in
      1) menuInvoke cfSetToken; menuPause ;;
      2) menuInvoke cfTunnelStatus; menuPause ;;
      3) menuInvoke cfTunnelRebuild; menuPause ;;
      4) menuInvoke cfDnsShow; menuPause ;;
      5) menuInvoke cfDomainMigrate; menuPause ;;
      6) menuInvoke cfstStatus; menuPause ;;
      7) menuInvoke cfstRefreshMenu; menuPause ;;
      8) menuInvoke cfstToggle; menuPause ;;
      9) menuInvoke cfstClear; menuPause ;;
      0) return ;;
      *) warn "Invalid";;
    esac
  done
}

menuSub() {
  while :; do
    cat <<'X'
[Subscription management]
  1) Regenerate subscriptions
  2) Rotate subscription link/main credential
  3) Show subscriptions(with QR codes)
  4) Export current configuration to file
  0) Back
X
    local c; read -r -p "Select: " c || true
    case "$c" in
      1) menuInvoke subRegenAll; menuPause ;;
      2) menuInvoke subRotateToken; menuPause ;;
      3) menuInvoke subShow; menuPause ;;
      4) menuInvoke subExportCurrent; menuPause ;;
      0) return ;;
      *) warn "Invalid";;
    esac
  done
}

menuSvc() {
  while :; do
    cat <<'X'
[Service management]
  1) All status
  2) Restart all
  3) Recent error logs
  0) Back
X
    local c; read -r -p "Select: " c || true
    case "$c" in
      1) menuInvoke svcStatusAll; menuPause ;;
      2) menuInvoke svcRestartAll; menuPause ;;
      3) menuInvoke svcLogTailErrors; menuPause ;;
      0) return ;;
      *) warn "Invalid";;
    esac
  done
}

menuDiag() {
  while :; do
    cat <<'X'
[Diagnostics]
  1) Overview
  2) Port/CDN path probe
  3) Xray self-test
  4) sing-box self-test
  5) Certificate/renewal status
  6) Egress IP
  7) Kernel parameters
  8) hop rules
  0) Back
X
    local c; read -r -p "Select: " c || true
    case "$c" in
      1) menuInvoke diagOverview; menuPause ;;
      2) menuInvoke diagPorts; menuPause ;;
      3) menuInvoke diagXraySelfCheck; menuPause ;;
      4) menuInvoke diagSboxSelfCheck; menuPause ;;
      5) menuInvoke certShow; menuPause ;;
      6) menuInvoke diagEgress; menuPause ;;
      7) menuInvoke diagKernel; menuPause ;;
      8) menuInvoke diagHop; menuPause ;;
      0) return ;;
      *) warn "Invalid";;
    esac
  done
}

menuUpgrade() {
  while :; do
    cat <<'X'
[upgrade]
  1) install.sh self
  2) Xray
  3) sing-box
  4) cloudflared
  5) acme.sh
  0) Back
X
    local c; read -r -p "Select: " c || true
    case "$c" in
      1) menuInvoke upgradeSelf; menuPause ;;
      2) menuInvoke upgradeXray; menuPause ;;
      3) menuInvoke upgradeSbox; menuPause ;;
      4) menuInvoke upgradeCFD; menuPause ;;
      5) menuInvoke upgradeAcme; menuPause ;;
      0) return ;;
      *) warn "Invalid";;
    esac
  done
}

menuBackup() {
  while :; do
    cat <<'X'
[Backup and Restore]
  1) Create backup
  2) List
  3) Restore
  0) Back
X
    local c; read -r -p "Select: " c || true
    case "$c" in
      1) menuInvoke backupCreate; menuPause ;;
      2) menuInvoke backupList; menuPause ;;
      3) menuInvoke backupRestore; menuPause ;;
      0) return ;;
      *) warn "Invalid";;
    esac
  done
}

menuAdvanced() {
  while :; do
    cat <<'X'
[Advanced/experimental]
  1) Toggle whether mihomo includes NaiveProxy
  2) Toggle SNI dry_run
  3) Force-rewrite all units
  4) View state
  5) Edit state
  6) Toggle SNI auto_rotate
  7) Reset Reality keys/credentials
  8) Switch certificate CA
  9) Restart one service
 10) Start/stop one service
 11) Follow service logs
 12) Export diagnostics bundle
 13) Delete Tunnel only(danger)
 14) RealiTLScanner raw scan(danger)
  0) Back
X
    local c; read -r -p "Select: " c || true
    case "$c" in
      1) menuInvoke advToggleNaiveInMihomo; menuPause ;;
      2) menuInvoke advToggleSniDryRun; menuPause ;;
      3) menuInvoke advRewriteUnits; menuPause ;;
      4) menuInvoke advDumpState; menuPause ;;
      5) menuInvoke advEditState; menuPause ;;
      6) menuInvoke advToggleSniAutoRotate; menuPause ;;
      7) menuInvoke realityResetCredentials; menuPause ;;
      8) menuInvoke certSwitchCA; menuPause ;;
      9) menuInvoke svcRestartOne; menuPause ;;
      10) menuInvoke svcToggleOne; menuPause ;;
      11) menuInvoke svcLogFollow; menuPause ;;
      12) menuInvoke diagExport; menuPause ;;
      13) menuInvoke cfTunnelDeleteMenu; menuPause ;;
      14) menuInvoke advRealiTLScannerAddr; menuPause ;;
      0) return ;;
      *) warn "Invalid";;
    esac
  done
}

# ----- Protocol managementhelper functions -----
protoList() {
  banner "Protocol table"
  loadState; protoApplyOverride
  printf '%-3s %-4s %-28s %-5s %-7s %-4s %-12s %s\n' "No." "Enabled" "tag" "core" "port" "cdn" "hop" "Description"
  local tag enabled note idx=1
  for tag in "${PROTO_TAGS[@]}"; do
    enabled=$(protoIsDisabled "$tag" && echo "No" || echo "Yes")
    note=""
    [[ "$tag" == "R-VLESS-Vision" ]] && note="fixed 443/tcp; enabled by default"
    [[ "$tag" == "C-VLESS-XHTTP" ]] && note="CDN XHTTP H3, path=$(cdnPath "$tag")"
    [[ "$tag" == "D-NaiveProxy" ]] && note="mihomo not compatible"
    printf '%-3s %-4s %-28s %-5s %-7s %-4s %-12s %s\n' \
      "$idx" "$enabled" "$tag" "${PROTO_CORE[$tag]}" "${PROTO_PORT[$tag]}" \
      "${PROTO_CDN[$tag]}" "${PROTO_HOP[$tag]:--}" "$note"
    idx=$((idx + 1))
  done
}

protoPickTag() {
  local __out=$1 c idx tag
  protoList
  prompt c "Enter protocol number"
  [[ -n "$c" ]] || return 1
  if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#PROTO_TAGS[@]} )); then
    printf -v "$__out" '%s' "${PROTO_TAGS[$((c - 1))]}"
    return 0
  fi
  for tag in "${PROTO_TAGS[@]}"; do
    [[ "$c" == "$tag" ]] && { printf -v "$__out" '%s' "$tag"; return 0; }
  done
  warn "Invalid protocol number: $c"
  return 1
}

protoEnabledAdd() {
  local tag=$1
  jqset "$STATE_FILE" "(.proto_enabled // [\"R-VLESS-Vision\"]) |= (. + [\"$tag\"] | unique)"
}

protoEnabledRemove() {
  local tag=$1
  jqset "$STATE_FILE" "(.proto_enabled // [\"R-VLESS-Vision\"]) |= map(select(. != \"$tag\"))"
}

protoRuntimeRefresh() {
  protoApplyOverride
  unitHop
  systemctl daemon-reload 2>/dev/null || true
  systemctl restart "$UNIT_HOP" 2>/dev/null || true
  xrayConfigAssemble; sboxConfigAssemble
  systemctl restart "$UNIT_XRAY" "$UNIT_SBOX" "$UNIT_CFD" "$UNIT_SUB" 2>/dev/null || true
  subRegenAllCore
}

protoPickTagList() {
  # Multi-select syntax: numbers separated by commas / a selects all / press Enter to cancel.
  # write the result to global __PROTO_PICK_RESULT(newline-separated tag list).
  __PROTO_PICK_RESULT=""
  protoList
  cat <<'EOF'
Enter the protocol numbers to operate on, separate multiple numbers with commas.
enter a to select all; press Enter to cancel this operation.
Example: 1,4,9
EOF
  local input
  read -r -p "Protocol selection: " input || true
  input="${input// /}"
  [[ -n "$input" ]] || { log "canceled"; return 1; }
  local out=""
  if [[ "${input,,}" == "a" ]]; then
    local t
    for t in "${PROTO_TAGS[@]}"; do out+="$t"$'\n'; done
  else
    local IFS=, parts n tag
    read -ra parts <<<"$input"
    for n in "${parts[@]}"; do
      [[ "$n" =~ ^[0-9]+$ ]] || { warn "Invalid number: $n"; return 1; }
      ((n >= 1 && n <= ${#PROTO_TAGS[@]})) || { warn "number out of range: $n"; return 1; }
      tag="${PROTO_TAGS[$((n - 1))]}"
      out+="$tag"$'\n'
    done
  fi
  __PROTO_PICK_RESULT="${out%$'\n'}"
  return 0
}

protoEnable() {
  local t="${1:-}"
  if [[ -n "$t" ]]; then
    [[ -n "${PROTO_CORE[$t]:-}" ]] || die "Unknown protocol: $t"
    protoEnabledAdd "$t"
    protoRuntimeRefresh
    ok "Enabled $t"
    return 0
  fi
  protoPickTagList || return 0
  local one
  while IFS= read -r one; do
    [[ -n "$one" ]] || continue
    [[ -n "${PROTO_CORE[$one]:-}" ]] || { warn "Skipping unknown protocol: $one"; continue; }
    protoEnabledAdd "$one"
    ok "Added to enabled set: $one"
  done <<<"$__PROTO_PICK_RESULT"
  protoRuntimeRefresh
}

protoDisable() {
  local t="${1:-}"
  if [[ -n "$t" ]]; then
    [[ -n "${PROTO_CORE[$t]:-}" ]] || die "Unknown protocol: $t"
    protoEnabledRemove "$t"
    protoRuntimeRefresh
    ok "Disabled $t"
    return 0
  fi
  protoPickTagList || return 0
  local one
  while IFS= read -r one; do
    [[ -n "$one" ]] || continue
    [[ -n "${PROTO_CORE[$one]:-}" ]] || { warn "Skipping unknown protocol: $one"; continue; }
    protoEnabledRemove "$one"
    ok "Removed from enabled set: $one"
  done <<<"$__PROTO_PICK_RESULT"
  protoRuntimeRefresh
}

protoChangePort() {
  local t="${1:-}" p="${2:-}"
  [[ -n "$t" ]] || protoPickTag t || return 0
  [[ -n "$p" ]] || prompt p "New port"
  [[ -n "$t" && -n "$p" ]] || return 0
  [[ "$t" != "R-VLESS-Vision" ]] || die "R-VLESS-Vision is fixed at 443/tcp; changing the port is not allowed"
  [[ -n "${PROTO_CORE[$t]:-}" ]] || die "Unknown protocol: $t"
  [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le 65535 ]] || die "port must be a number from 1 to 65535"
  # Conflict detection across PROTO_PORT and overrides
  protoApplyOverride
  local k
  for k in "${!PROTO_PORT[@]}"; do
    [[ "$k" == "$t" ]] && continue
    [[ "${PROTO_PORT[$k]}" == "$p" ]] && die "port conflict: $k already uses $p"
  done
  jqset "$STATE_FILE" ".proto_port_override[\"$t\"] = $p"
  protoRuntimeRefresh
  ok "$t port changed to $p"
}

protoResetAll() {
  if confirm "Confirm resetting the enabled protocol set to the default(R-VLESS-Vision only)and clearing port overrides?"; then
    protoEnableOnly '["R-VLESS-Vision"]'
    stateSetJson proto_port_override '{}'
    protoRuntimeRefresh
    ok "reset complete"
  fi
}

protoQuickSelect() {
  banner "Select default enabled protocols"
  protoList
  cat <<'EOF'
Enter the protocol numbers to enable, separate multiple numbers with commas.
enter a to select all; press Enter to enable only the default R-VLESS-Vision : 443/tcp.
Example: 1,4,9
EOF
  local input json
  read -r -p "Protocol selection: " input || true
  input="${input// /}"
  if [[ -z "$input" ]]; then
    json='["R-VLESS-Vision"]'
  elif [[ "${input,,}" == "a" ]]; then
    json=$(printf '%s\n' "${PROTO_TAGS[@]}" | jq -R . | jq -s -c '.')
  else
    local IFS=, parts n tag
    read -ra parts <<<"$input"
    json='[]'
    for n in "${parts[@]}"; do
      [[ "$n" =~ ^[0-9]+$ ]] || die "protocol number must be digits, commas, or a: $n"
      ((n >= 1 && n <= ${#PROTO_TAGS[@]})) || die "protocol number out of range: $n"
      tag="${PROTO_TAGS[$((n - 1))]}"
      json=$(jq -c --arg t "$tag" '. + [$t] | unique' <<<"$json")
    done
  fi
  protoEnableOnly "$json"
  protoApplyOverride
  ok "Saved enabled protocols: $(jq -r 'join(", ")' <<<"$json")"
}

protoRekeyUUID() {
  if confirm "Confirm rotation of the subscription link/main credential?old subscription links and old client main credentials will both become invalid"; then
    local u new old
    old=$(stateGet sub_token)
    u=$("$XRAY_BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    new=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
    stateSet uuid "$u"
    stateSet sub_token "$new"
    [[ -n "$old" && -d "${WEBROOT}/${old}" ]] && rm -rf "${WEBROOT:?}/${old}" 2>/dev/null || true
    xrayConfigAssemble; sboxConfigAssemble
    systemctl restart "$UNIT_XRAY" "$UNIT_SBOX" "$UNIT_SUB" 2>/dev/null || true
    subRegenAllCore
    ok "Rotated the main credential and subscription link"
    subShow
  fi
}

# ----- Certificate management -----
certShow() {
  banner "Certificate information"
  [[ -s "$CERT_FULLCHAIN" ]] || { warn "Certificate has not been issued"; return 0; }
  openssl x509 -in "$CERT_FULLCHAIN" -noout -issuer -subject -dates -ext subjectAltName -serial
  local end_ts now_ts remain_days
  end_ts=$(date -d "$(openssl x509 -in "$CERT_FULLCHAIN" -noout -enddate 2>/dev/null | sed 's/notAfter=//')" +%s 2>/dev/null || echo 0)
  now_ts=$(date +%s)
  if (( end_ts > 0 )); then
    remain_days=$(( (end_ts - now_ts) / 86400 ))
  else
    remain_days="-"
  fi
  printf 'Days remaining=%s\n' "$remain_days"
  echo
  printf 'Auto-renewal timer: active=%s enabled=%s\n' \
    "$(systemctl is-active "$UNIT_ACME_T" 2>/dev/null || echo inactive)" \
    "$(systemctl is-enabled "$UNIT_ACME_T" 2>/dev/null || echo disabled)"
  systemctl list-timers "$UNIT_ACME_T" --no-pager 2>/dev/null | sed -n '1,3p' || true
  echo
  printf 'Most recent renewal run(this invocation only):\n'
  local inv
  inv=$(systemctl show "$UNIT_ACME_S" -p InvocationID --value 2>/dev/null || true)
  if [[ -n "$inv" ]]; then
    journalctl _SYSTEMD_INVOCATION_ID="$inv" --no-pager 2>/dev/null | tail -n 12 || true
  else
    journalctl -u "$UNIT_ACME_S" -n 20 --no-pager 2>/dev/null | tail -n 8 || true
  fi
  echo
  printf 'Tip: if the log contains "Skipped <domain>" or "Skipping invalid cert", it means\n'
  printf '       acme.sh decided the certificate is still outside the renewal window and skipped it intentionally; this is normal.\n'
}

certRenew() {
  "$ACME_BIN" --renew -d "$ROOT_DOMAIN" --ecc --force >/dev/null
  systemctl restart "$UNIT_XRAY" "$UNIT_SBOX" 2>/dev/null || true
  ok "Certificate renewed and restart triggered"
}

certReissue() {
  rm -rf "${ACME_HOME}/${ROOT_DOMAIN}_ecc" 2>/dev/null || true
  acmeIssue
  acmeInstallCert
}

certSwitchCA() {
  local cur v
  cur=$(stateGet acme_ca); [[ -n "$cur" ]] || cur="letsencrypt"
  prompt v "CA (letsencrypt / zerossl / google)" "$cur"
  if [[ "$v" == "$cur" ]]; then
    log "CA unchanged(still $cur)"
    return 0
  fi
  case "$v" in
    zerossl)
      "$ACME_BIN" --register-account -m "$ACME_EMAIL" --server zerossl
      "$ACME_BIN" --set-default-ca --server zerossl
      ;;
    letsencrypt|google)
      "$ACME_BIN" --set-default-ca --server "$v"
      ;;
    *) die "Unknown CA";;
  esac
  stateSet acme_ca "$v"
  ok "Default CA switched to $v"
}

# ----- Service management -----
svcStatusAll() {
  banner "Service status"
  local u
  printf '  %-32s %-10s %-10s %s\n' "unit" "active" "enabled" "uptime"
  for u in "${ALL_UNITS[@]}"; do
    local active enabled since uptime="-"
    active=$(systemctl is-active "$u" 2>/dev/null || true)
    enabled=$(systemctl is-enabled "$u" 2>/dev/null || true)
    [[ -n "$active" ]] || active="inactive"
    [[ -n "$enabled" ]] || enabled="disabled"
    since=$(systemctl show "$u" -p ActiveEnterTimestamp --value 2>/dev/null || true)
    if [[ "$active" == "active" && -n "$since" ]]; then
      local ts now delta d h m
      ts=$(date -d "$since" +%s 2>/dev/null || echo 0)
      if (( ts > 0 )); then
        now=$(date +%s)
        delta=$(( now - ts ))
        d=$(( delta / 86400 ))
        h=$(( (delta % 86400) / 3600 ))
        m=$(( (delta % 3600) / 60 ))
        uptime="${d}d${h}h${m}m"
      fi
    fi
    printf '  %-32s %-10s %-10s %s\n' "$u" "$active" "$enabled" "$uptime"
  done
}

svcRestartAllCore() {
  systemctl restart "$UNIT_HOP"
  systemctl restart "$UNIT_XRAY" "$UNIT_SBOX" "$UNIT_CFD" "$UNIT_SUB"
  sleep 1
  local u
  for u in "$UNIT_HOP" "$UNIT_XRAY" "$UNIT_SBOX" "$UNIT_CFD" "$UNIT_SUB"; do
    [[ "$(systemctl is-active "$u" 2>/dev/null || true)" == "active" ]] || die "$u failed to start"
  done
}

svcRestartAll() {
  banner "Restart all services"
  local u
  for u in "$UNIT_HOP" "$UNIT_XRAY" "$UNIT_SBOX" "$UNIT_CFD" "$UNIT_SUB"; do
    if systemctl restart "$u" 2>/dev/null && [[ "$(systemctl is-active "$u" 2>/dev/null)" == "active" ]]; then
      ok "$u restarted"
    else
      err "$u restart failed"
    fi
  done
}

svcPickUnit() {
  # Important: do not name the local variable u, or it will shadow the caller's local u.
  # That would make printf -v "$__out" write to this function-local u while the caller remains unset -> set -u throws unbound.
  local __out=$1 idx=1 c __pu
  for __pu in "${ALL_UNITS[@]}"; do
    printf '  %d) %s\n' "$idx" "$__pu"
    idx=$((idx + 1))
  done
  # Do not provide a default unit; pressing Enter should not accidentally operate on janus-xray.service.
  prompt c "Select a unit number or name" ""
  [[ -n "$c" ]] || die "No unit selected"
  if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#ALL_UNITS[@]} )); then
    printf -v "$__out" '%s' "${ALL_UNITS[$((c - 1))]}"
    return 0
  fi
  for __pu in "${ALL_UNITS[@]}"; do
    if [[ "$c" == "$__pu" ]]; then
      printf -v "$__out" '%s' "$__pu"
      return 0
    fi
  done
  die "Unknown unit: $c"
}

svcRestartOne() {
  local u=""; svcPickUnit u
  if systemctl restart "$u" && systemctl is-active --quiet "$u"; then
    ok "$u restarted(active)"
  else
    err "$u restart failed"
    systemctl status "$u" --no-pager -l | sed -n '1,12p' || true
    return 1
  fi
}

svcToggleOne() {
  local u="" v rc=0
  svcPickUnit u
  prompt v "Action (start/stop/enable/disable)" ""
  [[ -n "$v" ]] || { warn "No action selected; canceled"; return 0; }
  case "$v" in
    start|stop|enable|disable) ;;
    *) die "Invalid action: $v(only start/stop/enable/disable are supported start/stop/enable/disable)";;
  esac
  systemctl "$v" "$u" || rc=$?
  # stop is intended to stop the service: rc=0 means it stopped as expected, and rc!=0 is failure.
  # Other actions: start must become active after success; enable/disable follow systemctl's exit code.
  if (( rc != 0 )); then
    err "$u $v failed"
    systemctl status "$u" --no-pager -l | sed -n '1,12p' || true
    return "$rc"
  fi
  case "$v" in
    start)
      if systemctl is-active --quiet "$u"; then
        ok "$u $v completed(active)"
      else
        err "$u $v did not enter active state after"
        systemctl status "$u" --no-pager -l | sed -n '1,12p' || true
        return 1
      fi
      ;;
    stop)
      if systemctl is-active --quiet "$u"; then
        err "$u stop command returned 0 but the service is still active"
        systemctl status "$u" --no-pager -l | sed -n '1,12p' || true
        return 1
      fi
      ok "$u stopped(inactive)"
      ;;
    enable|disable)
      ok "$u $v completed"
      ;;
  esac
}

svcLogFollow() {
  local u="${1:-}"
  if [[ -z "$u" ]]; then
    svcPickUnit u
  else
    # journalctl does not fail for unknown units; it only prints nothing, leaving CLI users waiting silently.
    # Validate explicitly here so `janus log <bad-unit>` fails immediately.
    systemctl list-unit-files "$u" --no-legend 2>/dev/null | grep -q "$u" \
      || die "Unknown unit: $u"
  fi
  journalctl -fu "$u" -n 200
}

svcLogTail() {
  local u=""; svcPickUnit u
  journalctl -u "$u" -n 200 --no-pager
}

svcLogTailErrors() {
  banner "Recent error logs"
  local u
  for u in "${ALL_UNITS[@]}"; do
    echo "---- $u ----"
    journalctl -u "$u" -p warning..alert -n 50 --no-pager 2>/dev/null | tail -n 20 || true
  done
}

# ----- Diagnostics -----
diagOverview() {
  banner "Health-check summary"
  local state_ok=1
  loadState || state_ok=0
  local u active
  for u in "$UNIT_XRAY" "$UNIT_SBOX" "$UNIT_CFD" "$UNIT_SUB"; do
    active=$(systemctl is-active "$u" 2>/dev/null || echo inactive)
    [[ "$active" == "active" ]] && ok "$u active" || warn "$u $active, check the recent error logs in the service menu"
  done
  [[ -s "$CERT_FULLCHAIN" ]] && ok "certificate file exists" || warn "certificate file missing"
  if (( state_ok )); then
    [[ -n "$(stateGet reality_sni)" ]] && ok "Reality SNI=$(stateGet reality_sni)" || warn "Reality SNI not set"
    [[ -n "$(stateGet sub_token)" ]] && ok "Subscription token initialized" || warn "Subscription token not initialized"
    [[ -n "$(stateGet cf_tunnel_id)" ]] && ok "Cloudflare Tunnel id recorded" || warn "Cloudflare Tunnel not recorded"
    local alert; alert=$(stateGet alert)
    if [[ -n "$alert" && "$alert" != "null" ]]; then
      warn "state.alert=$alert"
    fi
  else
    warn "state.json is empty or corrupted: skipping state field checks, restore or fix state first"
  fi
}

diagPorts() {
  banner "Port and path reachability"
  loadState || { warn "state.json is empty or corrupted: cannot check protocol ports and CDN paths"; return 1; }
  protoApplyOverride
  local tag port cdn
  for tag in "${PROTO_TAGS[@]}"; do
    cdn="${PROTO_CDN[$tag]}"; port="${PROTO_PORT[$tag]}"
    if [[ "$cdn" == "1" ]]; then
      printf '%-22s loopback :%-6s %s\n' "$tag" "$port" "$(ss -tlnH "sport = :$port" | grep -q . && echo LISTEN || echo MISS)"
    else
      printf '%-22s :%-6s %s\n' "$tag" "$port" "$(ss -tlnH "sport = :$port" 2>/dev/null | grep -q . || ss -ulnH "sport = :$port" 2>/dev/null | grep -q . && echo LISTEN || echo MISS)"
    fi
  done
  echo
  local cdn_host="${SUB_CDN}.${ROOT_DOMAIN}"
  for tag in C-VLESS-XHTTP C-VLESS-WS C-Trojan-WS C-VMess-WS C-VLESS-HTTPUpgrade; do
    local path code
    path=$(cdnPath "$tag")
    code=$(httpProbe "https://${cdn_host}${path}")
    printf 'cdn path %-24s (%s) -> HTTP %s\n' "$path" "$tag" "$code"
  done
  local code404; code404=$(httpProbe "https://${cdn_host}/random/nope")
  printf 'cdn path /random/nope -> HTTP %s (expected 404)\n' "$code404"
  printf 'r.%s:443 TLS:\n' "$ROOT_DOMAIN"
  tlsProbe "${SUB_R}.${ROOT_DOMAIN}" | head -n 10 || true
}

diagRealityHandshake() {
  banner "Xray self-test"
  local tmp out rc
  tmp=$(mktemp --suffix=.json)
  xrayConfigBuildFile "$tmp"
  if out=$("$XRAY_BIN" run -test -c "$tmp" 2>&1); then
    rc=0
  else
    rc=$?
  fi
  rm -f "$tmp"
  [[ -n "$out" ]] && printf '%s\n' "$out" | head -n 50
  if (( rc == 0 )); then
    ok "Xray config validation passed"
  else
    err "Xray config validation failed"
    return "$rc"
  fi
}

diagXraySelfCheck() {
  diagRealityHandshake
}

diagSboxSelfCheck() {
  banner "sing-box self-test"
  local tmp out rc
  tmp=$(mktemp --suffix=.json)
  sboxConfigBuildFile "$tmp"
  if out=$("$SBOX_BIN" check -c "$tmp" 2>&1); then
    rc=0
  else
    rc=$?
  fi
  rm -f "$tmp"
  [[ -n "$out" ]] && printf '%s\n' "$out" | head -n 50
  if (( rc == 0 )); then
    ok "sing-box config validation passed"
  else
    err "sing-box config validation failed"
    return "$rc"
  fi
}

diagEgress() {
  banner "Egress IP / ASN"
  curl -fsS --max-time 8 https://ipinfo.io 2>/dev/null | jq . || curl -fsS --max-time 8 https://ifconfig.co/json | jq .
}

diagKernel() {
  banner "Kernel parameters"
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc \
         net.core.rmem_max net.core.wmem_max net.ipv4.ip_forward
}

diagHop() {
  banner "UDP hop rules"
  # janus-hop.service installs iptables rules only when U-Hysteria2 or U-TUIC-v5 is enabled.
  # If both are disabled, the unit degrades to /bin/true and no janus_hop_* entries in nat are expected.
  loadState
  if protoIsDisabled "U-Hysteria2" && protoIsDisabled "U-TUIC-v5"; then
    log "U-Hysteria2 / U-TUIC-v5 are both disabled; port-hopping rules are empty as expected"
    return 0
  fi
  iptables-save -t nat 2>/dev/null | grep janus_hop || warn "no v4 rule detected"
  ip6tables-save -t nat 2>/dev/null | grep janus_hop || warn "no v6 rule detected"
}

diagExport() {
  banner "Export diagnostics bundle"
  local ts; ts=$(date +%Y%m%d%H%M%S)
  local dir; dir=$(mktemp -d)
  jq '{
        schema_version, ns, install_step, domain, acme_email, ipv4, ipv6,
        reality_sni, last_known_good_sni, sni_override, sni_auto_rotate, sni_dry_run,
        sni_grace_server_names, sni_history, reality_mldsa65_enabled,
        xhttp_path, grpc_service_name, cf_account_id, cf_zone_id, cf_tunnel_id,
        cf_tunnel_name, acme_ca, proto_enabled, proto_port_override,
        sub_include_naive_mihomo, sub_darkhttpd_port, cfst_enabled, cfst_best_ip,
        cfst_best_region, cfst_best_speed, cfst_updated_at, alert, ports,
        created_at, updated_at, sni_last_score_summary
      }' "$STATE_FILE" > "${dir}/state.json"
  local status_units=() unit
  for unit in "${ALL_UNITS[@]}"; do
    [[ "$unit" == "$UNIT_CFD" ]] || status_units+=("$unit")
  done
  systemctl status "${status_units[@]}" --no-pager > "${dir}/systemctl.txt" 2>&1 || true
  {
    printf '\n=== %s summary ===\n' "$UNIT_CFD"
    systemctl show "$UNIT_CFD" --no-pager \
      --property=Id,Description,LoadState,ActiveState,SubState,UnitFileState,FragmentPath
  } >> "${dir}/systemctl.txt" 2>&1 || true
  # Historical Janus journals may contain old tokenized subscription webroot paths.
  journalctl -u 'janus-*' -n 200 --no-pager 2>&1 \
    | sed -E 's#(/var/lib/janus/web/)[^/[:space:]]+#\1<redacted-token>#g' \
    > "${dir}/journal.txt" || true
  ip route > "${dir}/ip-route.txt" 2>&1 || true
  iptables-save  > "${dir}/iptables.txt" 2>&1 || true
  ip6tables-save > "${dir}/ip6tables.txt" 2>&1 || true
  if have ufw; then
    ufw status verbose > "${dir}/ufw.txt" 2>&1 || true
  fi
  local out="${BACKUP_DIR}/diag-${ts}.tar.gz"
  install -d -m 700 "$BACKUP_DIR"
  ( umask 077; tar -czf "$out" -C "$dir" . )
  chmod 600 "$out"
  rm -rf "$dir"
  ok "diagnostics bundle: $out"
}

# ----- backup -----
backupCreate() {
  banner "Create backup"
  install -d -m 700 "$BACKUP_DIR"
  local ts; ts=$(date +%Y%m%d%H%M%S)
  local out="${BACKUP_DIR}/janus-${ts}.tar.gz"
  local stage; stage=$(mktemp -d)
  mkdir -p "${stage}/janus/etc"
  if ! cp -a /etc/janus "${stage}/janus/etc/"; then
    rm -rf "$stage"
    die "backup snapshot creation failed"
  fi
  if ! jq -n --arg ver "$VERSION" --arg ts "$(date -u +%FT%TZ)" \
        --arg kernel "$(uname -r)" --arg distro "$(awk -F= '$1=="PRETTY_NAME"{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null)" \
        '{janus_version:$ver, created_at:$ts, kernel:$kernel, distro:$distro}' > "${stage}/janus/manifest.json"; then
    rm -rf "$stage"
    die "backup manifest creation failed"
  fi
  if ! ( umask 077; tar -czf "$out" -C "$stage" janus ); then
    rm -rf "$stage"
    rm -f "$out"
    die "backup archive creation failed"
  fi
  chmod 600 "$out"
  rm -rf "$stage"
  ok "backup completed: $out"
}

__backup_files=()
backupCollect() {
  __backup_files=()
  shopt -s nullglob
  local f
  for f in "$BACKUP_DIR"/janus-*.tar.gz; do
    __backup_files+=("$f")
  done
  shopt -u nullglob
}

backupList() {
  banner "Backup list"
  backupCollect
  if (( ${#__backup_files[@]} == 0 )); then
    warn "No backups"
    return 0
  fi
  local idx=1 f size mt
  printf '%-3s %-10s %-19s %s\n' "No." "Size" "Modified time" "Filename"
  for f in "${__backup_files[@]}"; do
    size=$(du -h "$f" 2>/dev/null | awk '{print $1}')
    mt=$(date -r "$f" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -c '%y' "$f" 2>/dev/null | cut -c1-19)
    printf '%-3s %-10s %-19s %s\n' "$idx" "${size:--}" "${mt:--}" "$(basename "$f")"
    idx=$((idx + 1))
  done
}

backupPickFile() {
  # The list has already been displayed; let the user enter a number and write it to the variable named by $1.
  local __outvar=$1 _bp_c _bp_n
  prompt _bp_c "Backup number"
  [[ -n "$_bp_c" ]] || return 1
  [[ "$_bp_c" =~ ^[0-9]+$ ]] || { warn "Enter a number"; return 1; }
  _bp_n="$_bp_c"
  ((_bp_n >= 1 && _bp_n <= ${#__backup_files[@]})) || { warn "number out of range"; return 1; }
  printf -v "$__outvar" '%s' "${__backup_files[$((_bp_n - 1))]}"
  return 0
}

backupRestoreReplaceTree() {
  local src=$1
  mkdir -p "$WORKDIR" || return 1
  find "$WORKDIR" -mindepth 1 -delete || return 1
  cp -a "${src}/." "$WORKDIR/" || return 1
}

backupRestoreRollbackTree() {
  # Move the failed restore tree aside to a fresh stash dir before moving the
  # rollback tree back. This preserves both trees if either rename fails — the
  # previous version deleted $WORKDIR first, which lost the failed restore tree
  # whenever the second mv failed (despite the error message claiming both were kept).
  local rollback=$1
  __backup_failed_tree=""
  local stash
  stash=$(mktemp -d /etc/.janus-restore-failed.XXXXXX) || return 1
  if ! mv "$WORKDIR" "${stash}/janus"; then
    rmdir "$stash" 2>/dev/null || rm -rf "$stash"
    return 1
  fi
  __backup_failed_tree="${stash}/janus"
  if ! mv "${rollback}/janus" "$WORKDIR"; then
    return 1
  fi
  rm -rf "$stash"
  __backup_failed_tree=""
}

backupRestoreRecover() {
  local rollback=$1 stage=$2 failure=$3
  warn "${failure}; rolling back the live Janus state"
  systemctl stop "${ALL_UNITS[@]}" 2>/dev/null || true
  if ! backupRestoreRollbackTree "$rollback"; then
    err "rollback failed; saved live Janus state is still kept at ${rollback}/janus"
    if [[ -n "${__backup_failed_tree:-}" && -d "$__backup_failed_tree" ]]; then
      err "failed restore tree is still kept at ${__backup_failed_tree}"
    elif [[ -d "$WORKDIR" ]]; then
      err "failed restore tree is still kept at $WORKDIR"
    fi
    die "${failure}; inspect the preserved trees before retrying"
  fi
  if ! ( backupRestoreRebuild ); then
    err "live Janus state was moved back, but rollback rebuild failed"
    die "${failure}; inspect Janus services before retrying"
  fi
  rm -rf "$stage" "$rollback"
  die "${failure}; live Janus state was restored"
}

backupRestoreRebuild() {
  loadState || return 1
  ROOT_DOMAIN=$(stateGet domain) || return 1; export ROOT_DOMAIN
  ACME_EMAIL=$(stateGet acme_email) || return 1; export ACME_EMAIL
  stateEnsureProtocolSecrets || return 1
  unitXray || return 1
  unitSingBox || return 1
  unitCloudflared || return 1
  unitSub || return 1
  unitHop || return 1
  unitSniRotate || return 1
  unitCfst || return 1
  unitAcmeRenew || return 1
  systemctl daemon-reload || return 1
  xrayConfigAssemble || return 1
  sboxConfigAssemble || return 1
  subRegenAllCore || return 1
  systemctl enable "$UNIT_HOP" "$UNIT_XRAY" "$UNIT_SBOX" "$UNIT_CFD" "$UNIT_SUB" >/dev/null 2>&1 || true
  svcRestartAllCore || return 1
  systemctl enable --now "$UNIT_SNI_T" "$UNIT_ACME_T" >/dev/null 2>&1 || true
  cfstTimerApply || return 1
}

backupRestore() {
  backupList
  (( ${#__backup_files[@]} > 0 )) || return 0
  local f stage restore_root rollback
  backupPickFile f || return 0
  [[ -s "$f" ]] || die "Invalid file: $f"
  if confirm "Restore from $f? This will overwrite /etc/janus/"; then
    stage=$(mktemp -d)
    if ! tar -xzf "$f" -C "$stage" janus/ 2>/dev/null; then
      rm -rf "$stage"
      die "extraction failed"
    fi
    restore_root="${stage}/janus/etc/janus"
    if [[ ! -d "$restore_root" || ! -s "${restore_root}/state.json" ]]; then
      rm -rf "$stage"
      die "backup does not contain a usable janus/etc/janus/state.json"
    fi
    if ! jq -e . "${restore_root}/state.json" >/dev/null 2>&1; then
      rm -rf "$stage"
      die "backup state.json is not valid JSON"
    fi

    rollback=$(mktemp -d /etc/.janus-restore-live.XXXXXX)
    mkdir -p "$WORKDIR"
    systemctl stop "${ALL_UNITS[@]}" 2>/dev/null || true
    if ! mv "$WORKDIR" "${rollback}/janus"; then
      rm -rf "$stage" "$rollback"
      die "could not move the live Janus state aside before restore"
    fi

    if ! backupRestoreReplaceTree "$restore_root"; then
      backupRestoreRecover "$rollback" "$stage" "restore copy failed"
    fi
    if ! ( backupRestoreRebuild ); then
      backupRestoreRecover "$rollback" "$stage" "restore rebuild failed"
    fi
    rm -rf "$stage" "$rollback"
    ok "Restored"
  fi
}

# ----- Advanced menu -----
advToggleSniDryRun() {
  local cur; cur=$(stateGet sni_dry_run); local nv="true"
  [[ "$cur" == "true" ]] && nv="false"
  stateSetJson sni_dry_run "$nv"
  ok "sni_dry_run=$nv"
}

advDumpState() {
  jq . "$STATE_FILE"
}

advEditState() {
  ${EDITOR:-vi} "$STATE_FILE"
  jq . "$STATE_FILE" >/dev/null || die "state.json is not valid JSON after exit; fix it"
  ok "state.json validation passed"
}

sniSetAutoRotate() {
  local nv=$1 cur
  case "$nv" in
    true|false) ;;
    on) nv=true ;;
    off) nv=false ;;
    *) die "Usage: janus sni auto <on|off>";;
  esac
  cur=$(stateGet sni_auto_rotate)
  if [[ "$cur" == "$nv" ]]; then
    ok "sni_auto_rotate=$nv(no change needed)"
    return 0
  fi
  if [[ "$nv" == "true" ]]; then
    warn "after auto_rotate is enabled, the daily timer fires, and automatically applies the highest-scoring SNI"
    warn "serverNames keep old/new values for 24-72h during switching, client subscriptions must be refreshed to apply the new serverName"
    confirm "Confirm enabling?" || return 0
  fi
  stateSetJson sni_auto_rotate "$nv"
  ok "sni_auto_rotate=$nv"
}

advToggleSniAutoRotate() {
  local cur nv
  cur=$(stateGet sni_auto_rotate)
  [[ "$cur" == "true" ]] && nv=false || nv=true
  sniSetAutoRotate "$nv"
}

# ----- modular installation -----
moduleSysDeps() {
  banner "System dependencies and kernel tuning"
  checkRoot; checkOS
  installDeps
  optionalToolsPrepare
  kernelTune
  loadState
  detectPublicIp
}

moduleInstallXray() { installXray; }
moduleInstallSbox() { installSingBox; }
moduleInstallCFD()  { installCloudflared; }

moduleInitState() {
  banner "Initialize state"
  loadState
  local u; u=$(stateGet uuid)
  if [[ -z "$u" ]]; then
    if [[ -x "$XRAY_BIN" ]]; then
      u=$("$XRAY_BIN" uuid 2>/dev/null)
    fi
    [[ -z "$u" ]] && u=$(cat /proc/sys/kernel/random/uuid)
    stateSet uuid "$u"
  fi
  local sid; sid=$(stateGet reality_shortid)
  [[ -z "$sid" ]] && stateSet reality_shortid "$(openssl rand -hex 8)"
  subToken >/dev/null
  stateEnsureProtocolSecrets
  # Reality keys
  local priv; priv=$(stateGet reality_privkey)
  if [[ -z "$priv" && -x "$XRAY_BIN" ]]; then
    realityRekey
  fi
  detectPublicIp
  ok "State initialization complete"
}

# ============ SECTION 19 quickInstall / uninstall / backup ============
quickInstall() {
  banner "Quick install (one-click 18-step flow)"
  if ! confirm "Continue? This will affect iptables, systemd, and Cloudflare DNS/Tunnel"; then
    return 0
  fi
  local step_start=0
  if have jq && [[ -f "$STATE_FILE" ]]; then
    loadState
    step_start=$(stateGet install_step)
  fi
  [[ -z "$step_start" || "$step_start" == "null" ]] && step_start=0
  local total=18

  quickStepHealthy() {
    local n=$1
    case "$n" in
      1) depsAllInstalled ;;
      2) [[ -n "$(stateGet domain)" && -n "$(stateGet acme_email)" && -s "$CF_TOKEN_FILE" ]] ;;
      3) return 0 ;;
      4) [[ -x "$XRAY_BIN" ]] ;;
      5) [[ -x "$SBOX_BIN" ]] ;;
      6) [[ -x "$CFD_BIN" ]] ;;
      7) [[ -s "$CERT_FULLCHAIN" && -s "$CERT_KEY" ]] ;;
      8) [[ -n "$(stateGet uuid)" && -n "$(stateGet sub_token)" && -n "$(stateGet ipv4)" ]] ;;
      9) have socat && [[ -x "$INSTALL_SH_DEST" ]] && systemctl list-unit-files "$UNIT_SUB" --no-legend 2>/dev/null | grep -q "$UNIT_SUB" && systemctl is-active --quiet "$UNIT_SUB" ;;
      10) [[ -x "$CLI_PATH" && -x "$INSTALL_SH_DEST" ]] ;;
      11) [[ -n "$(stateGet reality_privkey)" && -n "$(stateGet reality_shortid)" ]] ;;
      12) [[ -n "$(stateGet reality_sni)" ]] ;;
      13) [[ "$(jq -r '(.proto_enabled // [] | length) > 0' "$STATE_FILE" 2>/dev/null || echo false)" == "true" ]] ;;
      14) [[ -n "$(stateGet cf_tunnel_id)" && -s "$CFD_TOKEN_FILE" ]] ;;
      15) [[ -n "$(stateGet cf_tunnel_id)" ]] ;;
      16)
        local tok latest
        tok=$(stateGet sub_token)
        latest="${WEBROOT}/${tok}/latest"
        [[ -n "$tok" && -d "$latest" && -s "${latest}/default" && -s "${latest}/mihomo" && -s "${latest}/mihomo-full" && -s "${latest}/sbox" ]]
        ;;
      17)
        systemctl is-active --quiet "$UNIT_XRAY" && \
        systemctl is-active --quiet "$UNIT_SBOX" && \
        systemctl is-active --quiet "$UNIT_CFD" && \
        systemctl is-active --quiet "$UNIT_SUB"
        ;;
      18) return 1 ;;
      *) return 1 ;;
    esac
  }

  __qi_step() {
    local n=$1 title=$2 fn=$3
    if (( step_start >= n )) && quickStepHealthy "$n"; then
      log "step $n/$total $title (local state is available; skipping)"
      return 0
    fi
    step "step $n/$total $title"
    "$fn"
    [[ -f "$STATE_FILE" ]] || loadState
    stateSet install_step "$n"
  }

  __qi_step 1  "System dependencies and kernel tuning"           moduleSysDeps
  __qi_step 2  "Environment variables and CF preflight"            __qi_env
  __qi_step 3  "Firewall"                         moduleFirewall
  __qi_step 4  "Install Xray"                      moduleInstallXray
  __qi_step 5  "Install sing-box"                  moduleInstallSbox
  __qi_step 6  "Install cloudflared"               moduleInstallCFD
  __qi_step 7  "Issue certificate"                       moduleAcme
  __qi_step 8  "Initialize state"                   moduleInitState
  __qi_step 9  "Install subscription service"                   moduleInstallSubServer
  __qi_step 10 "Install CLI"                       moduleInstallCLI
  __qi_step 11 "Reality keys/short_id"          __qi_reality
  __qi_step 12 "Initial SNI selection"                   sniRotateNow
  __qi_step 13 "Protocol selection"                       protoQuickSelect
  __qi_step 14 "Tunnel provision + ingress"     __qi_tunnel
  __qi_step 15 "DNS provisioning"                       cfDnsBootstrap
  __qi_step 16 "Generate all subscriptions"                   subRegenAllCore
  __qi_step 17 "Restart all services"                   __qi_units_and_restart
  __qi_step 18 "Overview and subscriptions"                     diagOverview

  stateSet install_step "$total"
  ok "Quick install complete. Import the subscription with your client."
  subShow
}

__qi_env() { requireEnv; cfTokenPreflight; }
__qi_reality() {
  [[ -n "$(stateGet reality_privkey)" ]] || realityRekey
  [[ -n "$(stateGet reality_shortid)" ]] || realityReshortid
}
__qi_tunnel() {
  cfTunnelProvision
  cfTunnelConfigPut "$(stateGet cf_tunnel_id)" "$(cfTunnelIngressBuild)"
}
__qi_units_and_restart() {
  unitXray; unitSingBox; unitCloudflared; unitSub; unitHop
  unitSniRotate; unitCfst; unitAcmeRenew
  systemctl daemon-reload
  systemctl enable "$UNIT_HOP" "$UNIT_XRAY" "$UNIT_SBOX" "$UNIT_CFD" "$UNIT_SUB" >/dev/null
  systemctl enable --now "$UNIT_SNI_T" "$UNIT_ACME_T" >/dev/null
  # CFST timer is opt-in: cfstTimerApply enforces state.cfst_enabled (default false),
  # which explicitly disables any leftover timer from a previous install.
  cfstTimerApply
  xrayConfigAssemble
  sboxConfigAssemble
  svcRestartAllCore
}

doUninstall() {
  banner "Uninstall janus"
  local ans
  read -r -p 'Type the literal "UNINSTALL" to confirm: ' ans
  [[ "$ans" == "UNINSTALL" ]] || { warn "Not confirmed; canceled"; return 0; }

  local clean_remote=1
  if ! confirm "Also delete the remote Cloudflare Tunnel and the three subdomain DNS records?"; then
    clean_remote=0
  fi

  step "Stop and delete systemd units"
  systemctl disable --now "${ALL_UNITS[@]}" 2>/dev/null || true
  local u
  for u in "${ALL_UNITS[@]}"; do
    rm -f "/etc/systemd/system/${u}"
  done
  systemctl daemon-reload

  step "Clean up iptables/ip6tables NAT rules"
  iptables-save -t nat 2>/dev/null | grep -E "janus_hop_" | sed 's/^-A /iptables -t nat -D /' | sh 2>/dev/null || true
  ip6tables-save -t nat 2>/dev/null | grep -E "janus_hop_" | sed 's/^-A /ip6tables -t nat -D /' | sh 2>/dev/null || true

  # ufw is no longer managed by this script; no allow rules need to be cleaned up.

  if (( clean_remote )); then
    step "Clean up remote Cloudflare Tunnel + DNS"
    if [[ -f "$STATE_FILE" ]]; then
      requireEnv 2>/dev/null || true
      local tid; tid=$(stateGet cf_tunnel_id)
      [[ -n "$tid" ]] && cfTunnelDelete "$tid" 2>/dev/null || true
      local root; root=$(stateGet domain)
      if [[ -n "$root" ]]; then
        local n
        for n in "${SUB_R}.${root}" "${SUB_CDN}.${root}" "${SUB_SUB}.${root}"; do
          cfRecordDelete "$n" A     2>/dev/null || true
          cfRecordDelete "$n" AAAA  2>/dev/null || true
          cfRecordDelete "$n" CNAME 2>/dev/null || true
        done
      fi
    fi
  fi

  step "Delete local directories and CLI"
  rm -rf /etc/janus/ /var/lib/janus/
  rm -f "$CLI_PATH"
  rm -f /etc/sysctl.d/99-janus.conf
  rmdir /etc/janus 2>/dev/null || rm -rf /etc/janus

  ok "janus has been uninstalled. Core binaries (xray / sing-box / cloudflared / acme.sh) remain in /usr/local/bin/ and /root/.acme.sh/"
  log "For complete cleanup: rm -f /usr/local/bin/{xray,sing-box,cloudflared}; rm -rf /root/.acme.sh"
}

# ============ SECTION 20 entry dispatch ============
# onErr / onExit implementation(declared in the tool area after SECTION 02)
onErr() {
  local code=$1 line=$2 cmd=$3
  if [[ "${JANUS_MENU_CONTEXT:-0}" == "1" ]]; then
    # In menu context, line/cmd/exit usually point to menuInvoke's set+e wrapper and are not useful diagnostics for users.
    # The real error has already been printed by upstream die/err/warn. Print only a non-spamming fallback hint here.
    err "Menu operation failed; check the error above and retry"
    return 0
  fi
  local step_val=""
  [[ -f "$STATE_FILE" ]] && step_val=$(stateGet install_step 2>/dev/null || true)
  err "failed: line=${line} cmd=[${cmd}] exit=${code} install_step=${step_val:-?}"
  err "To resume from the checkpoint: sudo janus quick"
}

onExit() {
  rm -f /tmp/janus-* 2>/dev/null || true
}

# help
__help_main() {
  cat <<EOF
janus v${VERSION} - VPS first-hop multi-protocol management console

Usage:
  janus                       open the interactive menu
  janus menu                  same as above
  janus quick                 run quick install
  janus status                diagnostics overview
  janus log <unit>            journalctl -fu <unit>
  janus sni    <check|rotate|show|set|clear|auto on|auto off>
  janus proto  <list|enable <tag>|disable <tag>|port <tag> <port>|reset>
  janus sub    <regen|rotate|show|export>
  janus cfst   <status|refresh|on|off|clear>
  janus cf     <migrate <new-root>|dns|tunnel>
  janus cert   <show|ca <name>>
  janus svc    <status|restart-all>            (restart|toggle is for advanced/maintenance)
  janus diag   <overview|ports|xray|sbox|egress|kernel|hop|export>
  janus upgrade <self|xray|sbox|cfd|acme>
  janus backup <create|list|restore>
  janus restore               select from the backup list and restore
  janus uninstall             Uninstall
  janus --help                show this help
EOF
}

__help_sub() {
  case "$1" in
    sni)
      cat <<'EOF'
janus sni <subcmd>
  check                       probe and warn only(no rotation)
  rotate                      rotate immediately(with grace validation)
  show                        current status
  set                         Set override
  clear                       Clear override
  auto <on|off>               Toggle auto_rotate
EOF
      ;;
    proto)
      cat <<'EOF'
janus proto <subcmd>
  list
  enable <tag>
  disable <tag>
  port <tag> <port>
  reset
EOF
      ;;
    sub)
      cat <<'EOF'
janus sub <subcmd>
  regen | rotate | show | export
EOF
      ;;
    cfst)
      cat <<'EOF'
janus cfst <subcmd>
  status                      Show CFST status
  refresh                     Run CFST now and refresh subscriptions
  on | off                    enable/disable VPS-side CFST
  clear                       clear the preferred IP, fall back to cdn.<root>
EOF
      ;;
    cf)
      cat <<'EOF'
janus cf <subcmd>
  migrate <new-root>           Domain migration(hard switch, new sub_token)
  dns                          Show DNS
  tunnel                       Tunnel status
EOF
      ;;
    cert)
      cat <<'EOF'
janus cert <subcmd>
  show                         Certificate/renewal status
  ca                           advanced maintenance: Switch default CA
EOF
      ;;
    diag)
      cat <<'EOF'
janus diag <subcmd>
  overview | ports | xray | sbox | egress | kernel | hop
  export                       advanced maintenance: Export diagnostics bundle
EOF
      ;;
    backup)
      cat <<'EOF'
janus backup <subcmd>
  create | list | restore
EOF
      ;;
    svc)
      cat <<'EOF'
janus svc <subcmd>
  status                       all unit status
  restart-all                  restart all units
  restart                      advanced/maintenance: Restart one unit
  toggle                       advanced/maintenance: single unit start/stop/enable/disable
(use this to follow a single unit log janus log <unit>)
EOF
      ;;
    upgrade)
      cat <<'EOF'
janus upgrade <subcmd>
  self | xray | sbox | cfd | acme
EOF
      ;;
    *) __help_main ;;
  esac
}

__help_fail() {
  __help_sub "$1"
  exit 1
}

# startup initialization(run before dispatch)
__startup_init() {
  # loadState returns 1 when state.json is corrupted or empty. Under set -e, letting that throw would prevent
  # `janus menu/status` from starting, so users could not use the "diagnostics/restore" path. Catch and warn here
  # so the upper-level menu/diagnostics remain available. State-dependent functions will report their own errors.
  if [[ -z "${CF_API_TOKEN:-}" && -f "$CF_TOKEN_FILE" ]]; then
    CF_API_TOKEN=$(<"$CF_TOKEN_FILE")
    export CF_API_TOKEN
  fi
  if ! loadState; then
    JANUS_STATE_LOAD_OK=0
    export JANUS_STATE_LOAD_OK
    warn "loadState failed: state.json may be empty or corrupted, menu/diagnostics remain available, but action commands may fail because required data is missing"
    return 0
  fi
  JANUS_STATE_LOAD_OK=1
  export JANUS_STATE_LOAD_OK
  if [[ -z "${ROOT_DOMAIN:-}" ]]; then
    ROOT_DOMAIN=$(stateGet domain)
    export ROOT_DOMAIN
  fi
  if [[ -z "${ACME_EMAIL:-}" ]]; then
    ACME_EMAIL=$(stateGet acme_email)
    export ACME_EMAIL
  fi
  protoApplyOverride
  protoAssertMetadata
  linkRenderersSelfCheck
}

main() {
  local cmd="${1:-menu}"; shift || true
  case "$cmd" in
    subserve) subServeOne ;;
    quick)       __startup_init; quickInstall ;;
    -h|--help|help)
      __help_main
      ;;
    menu|"")
      if ! have jq; then
        checkRoot
        warn "jq is not installed, installing base dependencies before opening the menu"
        installDeps
      fi
      __startup_init
      mainMenu
      ;;
    status)      __startup_init; diagOverview ;;
    log)
      __startup_init
      [[ $# -ge 1 ]] || die "Missing unit name"
      svcLogFollow "$1"
      ;;
    sni)
      __startup_init
      case "${1:-show}" in
        check) shift 2>/dev/null || true; sniCheckNow ;;
        rotate) shift 2>/dev/null || true; sniRotateNow ;;
        show) shift 2>/dev/null || true; sniStatus ;;
        set) shift 2>/dev/null || true; sniSetOverride ;;
        clear) shift 2>/dev/null || true; sniClearOverride ;;
        auto)
          shift 2>/dev/null || true
          case "${1:-}" in
            on)  sniSetAutoRotate true ;;
            off) sniSetAutoRotate false ;;
            --help|-h) __help_sub sni ;;
            *) __help_fail sni ;;
          esac
          ;;
        --help|-h) __help_sub sni ;;
        *) __help_fail sni ;;
      esac
      ;;
    proto)
      __startup_init
      case "${1:-list}" in
        list) shift 2>/dev/null || true; protoList ;;
        enable)
          shift 2>/dev/null || true
          [[ $# -ge 1 && -n "${1:-}" ]] || die "Usage: janus proto enable <tag>"
          protoEnable "$1"
          ;;
        disable)
          shift 2>/dev/null || true
          [[ $# -ge 1 && -n "${1:-}" ]] || die "Usage: janus proto disable <tag>"
          protoDisable "$1"
          ;;
        port)
          shift 2>/dev/null || true
          [[ $# -ge 2 && -n "${1:-}" && -n "${2:-}" ]] || die "Usage: janus proto port <tag> <port>"
          protoChangePort "$1" "$2"
          ;;
        reset) shift 2>/dev/null || true; protoResetAll ;;
        --help|-h) __help_sub proto ;;
        *) __help_fail proto ;;
      esac
      ;;
    sub)
      __startup_init
      case "${1:-show}" in
        regen) shift 2>/dev/null || true; subRegenAll ;;
        rotate) shift 2>/dev/null || true; subRotateToken ;;
        show) shift 2>/dev/null || true; subShow ;;
        export) shift 2>/dev/null || true; subExportCurrent ;;
        --help|-h) __help_sub sub ;;
        *) __help_fail sub ;;
      esac
      ;;
    cfst)
      __startup_init
      case "${1:-status}" in
        status) shift 2>/dev/null || true; cfstStatus ;;
        refresh)
          shift 2>/dev/null || true
          if [[ "${JANUS_CFST_AUTO:-0}" == "1" ]]; then
            cfstRefreshCore auto
          else
            cfstRefreshCore force
          fi
          ;;
        on) shift 2>/dev/null || true; cfstToggle on ;;
        off) shift 2>/dev/null || true; cfstToggle off ;;
        clear) shift 2>/dev/null || true; cfstClear ;;
        --help|-h) __help_sub cfst ;;
        *) __help_fail cfst ;;
      esac
      ;;
    cf)
      __startup_init
      case "${1:-}" in
        migrate) shift 2>/dev/null || true; cfDomainMigrate "${1:-}" ;;
        dns) shift 2>/dev/null || true; cfDnsShow ;;
        tunnel) shift 2>/dev/null || true; cfTunnelStatus ;;
        --help|-h) __help_sub cf ;;
        *) __help_fail cf ;;
      esac
      ;;
    cert)
      __startup_init
      case "${1:-show}" in
        show) shift 2>/dev/null || true; certShow ;;
        ca) shift 2>/dev/null || true; certSwitchCA ;;
        --help|-h) __help_sub cert ;;
        *) __help_fail cert ;;
      esac
      ;;
    svc)
      __startup_init
      case "${1:-status}" in
        status) shift 2>/dev/null || true; svcStatusAll ;;
        restart-all) shift 2>/dev/null || true; svcRestartAll ;;
        restart) shift 2>/dev/null || true; svcRestartOne ;;
        toggle) shift 2>/dev/null || true; svcToggleOne ;;
        --help|-h) __help_sub svc ;;
        *) __help_fail svc ;;
      esac
      ;;
    diag)
      __startup_init
      case "${1:-overview}" in
        overview) shift 2>/dev/null || true; diagOverview ;;
        ports) shift 2>/dev/null || true; diagPorts ;;
        reality|xray) shift 2>/dev/null || true; diagXraySelfCheck ;;
        sbox|sing-box) shift 2>/dev/null || true; diagSboxSelfCheck ;;
        egress) shift 2>/dev/null || true; diagEgress ;;
        kernel) shift 2>/dev/null || true; diagKernel ;;
        hop) shift 2>/dev/null || true; diagHop ;;
        export) shift 2>/dev/null || true; diagExport ;;
        --help|-h) __help_sub diag ;;
        *) __help_fail diag ;;
      esac
      ;;
    upgrade)
      __startup_init
      case "${1:-self}" in
        self) shift 2>/dev/null || true; upgradeSelf ;;
        xray) shift 2>/dev/null || true; upgradeXray ;;
        sbox) shift 2>/dev/null || true; upgradeSbox ;;
        cfd) shift 2>/dev/null || true; upgradeCFD ;;
        acme) shift 2>/dev/null || true; upgradeAcme ;;
        --help|-h) __help_sub upgrade ;;
        *) __help_fail upgrade ;;
      esac
      ;;
    backup)
      __startup_init
      case "${1:-list}" in
        create) shift 2>/dev/null || true; backupCreate ;;
        list) shift 2>/dev/null || true; backupList ;;
        restore) shift 2>/dev/null || true; backupRestore ;;
        --help|-h) __help_sub backup ;;
        *) __help_fail backup ;;
      esac
      ;;
    restore)
      __startup_init
      backupRestore
      ;;
    uninstall)
      __startup_init
      doUninstall
      ;;
    *)
      __startup_init
      warn "Unknown command: $cmd"
      __help_main
      exit 1
      ;;
  esac
}

if [[ "${JANUS_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
