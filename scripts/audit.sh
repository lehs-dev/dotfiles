#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MANIFEST_DIR="$REPO_ROOT/manifests"
readonly CHECKSUM_FILE="$REPO_ROOT/inventory/SHA256SUMS"

die() {
  printf 'AUDIT FAILED: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '  OK  %s\n' "$*"
}

for command_name in find glib-compile-schemas jq sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 \
    || die "Required audit command is missing: $command_name"
done

bash -n "$REPO_ROOT/install.sh" "$REPO_ROOT/scripts/snapshot.sh" "$0"
note "Bash syntax"

[[ -x "$REPO_ROOT/install.sh" ]] || die "install.sh is not executable"
[[ -x "$REPO_ROOT/scripts/snapshot.sh" ]] || die "snapshot.sh is not executable"

while IFS= read -r allowed_path; do
  [[ -n "$allowed_path" && "$allowed_path" != \#* ]] || continue
  [[ "$allowed_path" != /* && "$allowed_path" != *'..'* ]] \
    || die "Unsafe home allowlist entry: $allowed_path"
done < "$MANIFEST_DIR/managed-home-paths.txt"

while IFS= read -r payload_path; do
  relative_path="${payload_path#home/}"
  allowed=0
  while IFS= read -r allowed_path; do
    [[ -n "$allowed_path" && "$allowed_path" != \#* ]] || continue
    if [[ "$relative_path" == "$allowed_path" || "$relative_path" == "$allowed_path/"* ]]; then
      allowed=1
      break
    fi
  done < "$MANIFEST_DIR/managed-home-paths.txt"
  ((allowed)) || die "Home payload is outside the explicit allowlist: $payload_path"
done < <(cd -- "$REPO_ROOT" && find home \( -type f -o -type l \) -print | LC_ALL=C sort)
note "Home payload allowlist"

for forbidden_path in \
  home/.codex/auth.json \
  home/.bash_history \
  home/.config/BraveSoftware \
  home/.config/mozilla \
  home/.config/goa-1.0 \
  home/.config/evolution \
  home/.config/dconf/user \
  home/.local/share/keyrings \
  home/.local/share/pki \
  home/.local/share/evolution \
  home/.local/state \
  home/.cache \
  home/.var; do
  [[ ! -e "$REPO_ROOT/$forbidden_path" ]] \
    || die "Private/runtime path entered the repository: $forbidden_path"
done

if find "$REPO_ROOT" -path "$REPO_ROOT/.git" -prune -o \
  -type f \( \
    -name auth.json -o -name '*.keyring' -o -name '*.keystore' -o \
    -name key4.db -o -name cert9.db -o -name '*.pem' -o -name '*.key' -o \
    -name '*.p12' -o -name '*.pfx' -o -name 'id_*' \
  \) -print -quit | grep -q .; then
  die "A forbidden credential filename exists in the repository"
fi

if grep -rIlE --exclude='SHA256SUMS' \
  '(-----BEGIN ([A-Z]+ )?PRIVATE KEY-----|sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|glpat-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|AIza[0-9A-Za-z_-]{30,}|AKIA[0-9A-Z]{16}|OPENAI_API_KEY[[:space:]]*=)' \
  "$REPO_ROOT/home" "$REPO_ROOT/dconf" "$REPO_ROOT/gnome" \
  "$REPO_ROOT/manifests" "$REPO_ROOT/repos" "$REPO_ROOT/inventory" \
  >/dev/null; then
  die "The payload contains text resembling a credential"
fi

if grep -rIlF -- '/home/' \
  "$REPO_ROOT/home" "$REPO_ROOT/dconf" "$REPO_ROOT/manifests" \
  "$REPO_ROOT/repos" "$REPO_ROOT/inventory" >/dev/null; then
  die "The portable payload contains a source-user absolute path"
fi

if grep -Eq '^\[projects\.|auth_json|OPENAI_API_KEY' \
  "$REPO_ROOT/home/.codex/config.toml"; then
  die "Codex configuration contains project trust or authentication material"
fi

if ! awk '
  /^[[:space:]]*($|#)/ { next }
  /^(model|model_reasoning_effort|service_tier|cli_auth_credentials_store)[[:space:]]*=/ { next }
  { exit 1 }
' "$REPO_ROOT/home/.codex/config.toml"; then
  die "Codex config contains a key outside its strict portability allowlist"
fi

jq -e 'keys == ["enable-crash-reporter"] and .["enable-crash-reporter"] == false' \
  "$REPO_ROOT/home/.vscode-oss/argv.json" >/dev/null \
  || die "VSCodium argv.json contains machine-specific fields"

jq -e '
  [paths(scalars) as $path
   | ($path | map(tostring) | join("."))
   | select(test("(token|secret|password|api.?key|authorization|credential)"; "i"))]
  | length == 0
' "$REPO_ROOT/home/.config/VSCodium/User/settings.json" >/dev/null \
  || die "VSCodium settings contain a key name that requires secret review"
note "Credential and machine-identity exclusions"

if find "$REPO_ROOT/home" "$REPO_ROOT/gnome/extensions" -mindepth 1 \
  ! -type d ! -type f -print -quit | grep -q .; then
  die "The executable payload contains a symlink or special file"
fi

if find "$REPO_ROOT/gnome/extensions" -type f -name gschemas.compiled -print -quit \
  | grep -q .; then
  die "Generated gschemas.compiled entered the extension bundle"
fi

# shellcheck source=/dev/null
source "$MANIFEST_DIR/system.env"
while IFS= read -r uuid; do
  [[ -n "$uuid" && "$uuid" != \#* ]] || continue
  [[ "$uuid" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]] \
    || die "Unsafe GNOME extension UUID: $uuid"

  extension_dir="$REPO_ROOT/gnome/extensions/$uuid"
  metadata="$extension_dir/metadata.json"
  [[ -f "$metadata" ]] || die "Missing extension metadata: $uuid"
  jq -e --arg uuid "$uuid" --arg major "$SNAPSHOT_GNOME_MAJOR" \
    '.uuid == $uuid and (."shell-version" | map(tostring) | index($major) != null)' \
    "$metadata" >/dev/null \
    || die "Extension UUID/version metadata mismatch: $uuid"

  if find "$extension_dir/schemas" -maxdepth 1 -type f -name '*.xml' \
    -print -quit 2>/dev/null | grep -q .; then
    glib-compile-schemas --strict --dry-run "$extension_dir/schemas"
  fi
done < "$MANIFEST_DIR/gnome-extensions.txt"

magic_patch="$REPO_ROOT/gnome/extensions/dash2dock-lite@icedman.github.com/integrations.js"
grep -Fq 'Main.layoutManager.primaryIndex' "$magic_patch" \
  || die "Magic Lamp primary-monitor dock fallback patch is missing"
grep -Fq 'return dockFallback;' "$magic_patch" \
  || die "Magic Lamp dock-edge fallback patch is missing"
note "GNOME metadata, schemas and Magic Lamp fallback patch"

while IFS='|' read -r dconf_path filename; do
  [[ -n "$dconf_path" && "$dconf_path" != \#* ]] || continue
  [[ "$dconf_path" =~ ^/org/gnome/[A-Za-z0-9_./-]+/$ ]] \
    || die "Unsafe dconf path in restore.map: $dconf_path"
  [[ "$filename" =~ ^[A-Za-z0-9._-]+\.ini$ ]] \
    || die "Unsafe dconf filename in restore.map: $filename"
  [[ -s "$REPO_ROOT/dconf/$filename" ]] \
    || die "Missing or empty mapped dconf file: $filename"
  grep -q '^\[/\]$' "$REPO_ROOT/dconf/$filename" \
    || die "Unexpected dconf dump format: $filename"
done < "$REPO_ROOT/dconf/restore.map"

if grep -RqsE '^(night-light-last-coordinates|monitor-count)=' "$REPO_ROOT/dconf"; then
  die "A device/runtime-specific dconf key entered the portable snapshot"
fi


bms_dump="$REPO_ROOT/dconf/extension-blur-my-shell.ini"
for component in overview appfolder applications dash-to-dock screenshot lockscreen window-list coverflow-alt-tab; do
  value="$(awk -v wanted="$component" '
    /^\[/ { section = substr($0, 2, length($0) - 2) }
    section == wanted && /^blur=/ { sub(/^blur=/, ""); print; exit }
  ' "$bms_dump")"
  [[ "$value" == "false" ]] \
    || die "Blur My Shell is not panel-only: $component blur=$value"
done
panel_value="$(awk '
  /^\[/ { section = substr($0, 2, length($0) - 2) }
  section == "panel" && /^blur=/ { sub(/^blur=/, ""); print; exit }
' "$bms_dump")"
[[ "$panel_value" == "true" ]] || die "Blur My Shell panel blur is not enabled"
note "Curated dconf map and sanitizers"

[[ -f "$CHECKSUM_FILE" ]] || die "Missing SHA256SUMS"
(cd -- "$REPO_ROOT" && sha256sum --check --quiet inventory/SHA256SUMS) \
  || die "Payload checksum mismatch"

checksum_inventory="$(mktemp "${TMPDIR:-/tmp}/dotfiles-checksums.XXXXXX")"
trap 'rm -f -- "$checksum_inventory"' EXIT
(
  cd -- "$REPO_ROOT"
  find dconf gnome home manifests repos -type f ! -name gschemas.compiled -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum
) > "$checksum_inventory"
cmp -s "$checksum_inventory" "$CHECKSUM_FILE" \
  || die "SHA256SUMS does not cover the exact regular-file payload"
note "Payload checksums"

printf '\nSnapshot audit passed.\n'
