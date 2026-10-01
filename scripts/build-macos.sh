#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DESKTOP_APP="${REPO_ROOT}/apps/desktop-app"
LOCK_DIR="${DESKTOP_APP}/target/.senju-build.lock"
MIN_RUST_VERSION="1.85"

# Returns 0 if $1 >= $2 (numeric semver, no sort -V).
semver_ge() {
  local IFS=.
  local -a a=($1) b=($2)
  local i av bv
  for i in 0 1 2; do
    av=${a[i]:-0}
    bv=${b[i]:-0}
    av=${av%%[^0-9]*}
    bv=${bv%%[^0-9]*}
    if ((10#${av} > 10#${bv})); then
      return 0
    fi
    if ((10#${av} < 10#${bv})); then
      return 1
    fi
  done
  return 0
}

# Returns 0 if $1 > $2.
semver_gt() {
  semver_ge "$1" "$2" || return 1
  [[ "$1" != "$2" ]] || return 1
  local IFS=.
  local -a a=($1) b=($2)
  local i av bv
  for i in 0 1 2; do
    av=${a[i]:-0}
    bv=${b[i]:-0}
    av=${av%%[^0-9]*}
    bv=${bv%%[^0-9]*}
    if ((10#${av} != 10#${bv})); then
      return 0
    fi
  done
  return 1
}

remove_lock_if_owned() {
  if [[ -f "${LOCK_DIR}/pid" ]] && [[ "$(cat "${LOCK_DIR}/pid")" == "$$" ]]; then
    rm -rf "${LOCK_DIR}"
  fi
}

acquire_build_lock() {
  mkdir -p "${DESKTOP_APP}/target"
  while true; do
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
      echo $$ >"${LOCK_DIR}/pid"
      return 0
    fi
    local other_pid=""
    if [[ -f "${LOCK_DIR}/pid" ]]; then
      other_pid="$(cat "${LOCK_DIR}/pid")"
    fi
    if [[ -n "${other_pid}" ]] && kill -0 "${other_pid}" 2>/dev/null; then
      echo "Another build is running (PID ${other_pid}). Waiting..."
      while kill -0 "${other_pid}" 2>/dev/null; do
        sleep 2
      done
      continue
    fi
    rm -rf "${LOCK_DIR}"
  done
}

setup_cargo() {
  if cargo --version >/dev/null 2>&1; then
    return 0
  fi
  local asdf_rust="${HOME}/.asdf/installs/rust"
  if [[ ! -d "${asdf_rust}" ]]; then
    echo "Stable Rust is required. Install from https://rustup.rs/" >&2
    exit 1
  fi
  local best_ver="" best_bin=""
  local ver dir
  for dir in "${asdf_rust}"/*; do
    [[ -d "${dir}" ]] || continue
    ver="$(basename "${dir}")"
    [[ -x "${dir}/bin/cargo" ]] || continue
    semver_ge "${ver}" "${MIN_RUST_VERSION}" || continue
    if [[ -z "${best_ver}" ]] || semver_gt "${ver}" "${best_ver}"; then
      best_ver="${ver}"
      best_bin="${dir}/bin"
    fi
  done
  if [[ -z "${best_bin}" ]]; then
    echo "Stable Rust is required. Install from https://rustup.rs/" >&2
    exit 1
  fi
  export PATH="${best_bin}:${PATH}"
  # asdf Rust installs cargo/rustc as rustup shims; need an explicit toolchain.
  export RUSTUP_TOOLCHAIN="${best_ver}"
  echo "Using asdf Rust ${best_ver} (${best_bin}/cargo)"
}

tauri_cli_is_v2() {
  local out=""
  out="$(cargo tauri --version 2>/dev/null)" || return 1
  [[ "${out}" =~ tauri-cli[[:space:]]2 ]]
}

ensure_tauri_cli() {
  if tauri_cli_is_v2; then
    return 0
  fi
  cargo install tauri-cli --version "^2" --locked
  if ! tauri_cli_is_v2; then
    echo "cargo tauri is not Tauri CLI 2.x after install." >&2
    exit 1
  fi
}

require_xcode_tools() {
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode or Command Line Tools are required. Install Xcode or run: xcode-select --install" >&2
    exit 1
  fi
  if ! xcrun --find clang >/dev/null 2>&1; then
    echo "Xcode or Command Line Tools are required. Install Xcode or run: xcode-select --install" >&2
    exit 1
  fi
}

macos_major_version() {
  sw_vers -productVersion | cut -d. -f1
}

# macOS 27+ rejects hdiutil create -srcfolder with EBUSY; create-dmg --sandbox-safe uses makehybrid.
bundle_dmg_sandbox_safe() {
  local bundle_macos bundle_dmg_dir script product version arch dmg_name app_name
  bundle_macos="${DESKTOP_APP}/target/release/bundle/macos"
  bundle_dmg_dir="${DESKTOP_APP}/target/release/bundle/dmg"
  script="${bundle_dmg_dir}/bundle_dmg.sh"

  if [[ ! -x "${script}" ]]; then
    echo "DMG bundling assets missing (${script})." >&2
    return 1
  fi

  product="$(
    python3 - "${DESKTOP_APP}/src-tauri/tauri.conf.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(json.load(f)["productName"])
PY
  )"
  version="$(
    python3 - "${DESKTOP_APP}/src-tauri/tauri.conf.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(json.load(f)["version"])
PY
  )"

  case "$(uname -m)" in
    arm64) arch=aarch64 ;;
    x86_64) arch=x64 ;;
    *)
      echo "Unsupported macOS architecture: $(uname -m)" >&2
      return 1
      ;;
  esac

  dmg_name="${product}_${version}_${arch}.dmg"
  app_name="${product}.app"

  if [[ ! -d "${bundle_macos}/${app_name}" ]]; then
    echo "App bundle not found: ${bundle_macos}/${app_name}" >&2
    return 1
  fi

  # The last argument is the folder whose children become the DMG root.
  # Passing the .app itself makes that root Contents/, so Finder shows a folder.
  local stage
  stage="$(mktemp -d)"
  ditto "${bundle_macos}/${app_name}" "${stage}/${app_name}"

  echo "Creating DMG with --sandbox-safe (macOS $(macos_major_version) hdiutil -srcfolder workaround)..."
  mkdir -p "${bundle_dmg_dir}"
  rm -f "${bundle_macos}/${dmg_name}" "${bundle_dmg_dir}/${dmg_name}"
  rm -f "${bundle_macos}"/rw.*.dmg "${bundle_dmg_dir}"/rw.*.dmg 2>/dev/null || true
  local rc=0
  "${script}" --sandbox-safe \
    --volname "${product}" \
    --icon "${app_name}" 180 170 \
    --app-drop-link 480 170 \
    --window-size 660 400 \
    --hide-extension "${app_name}" \
    --volicon "${bundle_dmg_dir}/icon.icns" \
    "${bundle_dmg_dir}/${dmg_name}" \
    "${stage}" || rc=$?
  /bin/rm -rf "${stage}"
  if ((rc != 0)); then
    return "${rc}"
  fi
}

run_tauri_build() {
  local macos_major
  macos_major="$(macos_major_version)"
  if ((macos_major >= 27)); then
    # hdiutil create -srcfolder returns EBUSY on macOS 27. Tauri still has to
    # write bundle_dmg.sh, so the default DMG step runs and is expected to fail.
    echo "macOS ${macos_major}: hdiutil -srcfolder cannot create the DMG. After that step fails, the script finishes it with bundle_dmg.sh --sandbox-safe."
    cargo tauri build --bundles app
    if ! cargo tauri build --bundles dmg; then
      bundle_dmg_sandbox_safe || exit 1
    fi
  else
    cargo tauri build
  fi
}

trap remove_lock_if_owned EXIT
acquire_build_lock
if [[ "${1:-}" == "--dmg-only" ]]; then
  bundle_dmg_sandbox_safe
else
  setup_cargo
  require_xcode_tools
  ensure_tauri_cli
  cd "${DESKTOP_APP}"
  run_tauri_build
fi

BUNDLE="${DESKTOP_APP}/target/release/bundle"
APP_PATH=""
DMG_PATH=""

shopt -s nullglob
apps=("${BUNDLE}/macos/"*.app)
dmgs=("${BUNDLE}/dmg/"*.dmg)
shopt -u nullglob

if ((${#apps[@]} == 0)); then
  echo "Build finished but no .app found under ${BUNDLE}/macos/" >&2
  exit 1
fi
if ((${#dmgs[@]} == 0)); then
  echo "Build finished but no .dmg found under ${BUNDLE}/dmg/" >&2
  exit 1
fi

APP_PATH="${apps[0]}"
DMG_PATH="${dmgs[0]}"

echo "App: ${APP_PATH}"
echo "DMG: ${DMG_PATH}"
