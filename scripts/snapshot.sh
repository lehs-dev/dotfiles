#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MANIFEST_DIR="$REPO_ROOT/manifests"
readonly SOURCE_EXTENSIONS="$HOME/.local/share/gnome-shell/extensions"

INCLUDE_MONITOR_LAYOUT=0
TMP_WORK=""

usage() {
  cat <<'EOF'
Usage: ./scripts/snapshot.sh [--include-monitor-layout]

Refresh the curated, portable snapshot from the current user account. Private
sessions, browser profiles, keyrings, Codex credentials and machine caches are
never copied. monitors.xml is omitted unless explicitly requested.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

cleanup() {
  if [[ -n "$TMP_WORK" && -d "$TMP_WORK" ]]; then
    rm -rf -- "$TMP_WORK"
  fi
}

trap cleanup EXIT
trap 'printf "ERROR: snapshot failed at line %s.\n" "$LINENO" >&2' ERR

while (($#)); do
  case "$1" in
    --include-monitor-layout) INCLUDE_MONITOR_LAYOUT=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "Unknown option: $1"
      ;;
  esac
  shift
done

((EUID != 0)) || die "Run this script as the desktop user, not root."

target_user="$(id -un)"
passwd_home="$(getent passwd "$target_user" | cut -d: -f6)"
[[ "$HOME" == "$passwd_home" ]] \
  || die "HOME ($HOME) does not match the passwd home for $target_user ($passwd_home)."

for command_name in dconf gsettings install jq rsync sed sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 \
    || die "Required command is missing: $command_name"
done

TMP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/fedora-dotfiles-snapshot.XXXXXX")"

copy_home_file() {
  local relative_path="$1"
  local mode="${2:-0644}"
  local source_path="$HOME/$relative_path"
  local target_path="$REPO_ROOT/home/$relative_path"

  [[ -f "$source_path" ]] || die "Required source file is missing: $source_path"
  install -Dm"$mode" "$source_path" "$target_path"
}

sync_home_directory() {
  local relative_path="$1"
  local source_path="$HOME/$relative_path"
  local target_path="$REPO_ROOT/home/$relative_path"

  [[ -d "$source_path" ]] || die "Required source directory is missing: $source_path"
  mkdir -p -- "$target_path"
  rsync -a --delete "$source_path/" "$target_path/"
}

log "Copying the explicit home-configuration allowlist"
copy_home_file ".bash_logout"
copy_home_file ".bash_profile"
copy_home_file ".bashrc"
copy_home_file ".config/VSCodium/User/settings.json"
copy_home_file ".config/environment.d/fcitx5.conf"
copy_home_file ".config/fcitx5/config"
copy_home_file ".config/fcitx5/profile"
copy_home_file ".config/fcitx5/conf/keyboard.conf"
copy_home_file ".config/fcitx5/conf/notifications.conf"
copy_home_file ".config/fcitx5/conf/unikey.conf"
copy_home_file ".config/fcitx5/conf/wayland.conf"
copy_home_file ".config/fish/config.fish"
sync_home_directory ".local/share/backgrounds"

sound_source="$HOME/.local/share/sounds/__custom/index.theme"
[[ -f "$sound_source" ]] || die "Custom sound theme index is missing: $sound_source"
mkdir -p -- "$TMP_WORK/sound-theme" "$REPO_ROOT/home/.local/share/sounds/__custom"
install -m0644 "$sound_source" "$TMP_WORK/sound-theme/index.theme"
rsync -a --delete "$TMP_WORK/sound-theme/" \
  "$REPO_ROOT/home/.local/share/sounds/__custom/"

jq empty "$REPO_ROOT/home/.config/VSCodium/User/settings.json"

# Use the family installed by install.sh. The live value "JetBrains Mono" does
# not match the bundled Nerd Font family and falls back through Fontconfig.
jq \
  '."editor.fontFamily" = "JetBrainsMono Nerd Font, Fira Code, Cascadia Code, Consolas, monospace"
   | ."terminal.integrated.fontFamily" = "JetBrainsMono Nerd Font, Fira Code, Cascadia Code, Consolas, monospace"' \
  "$REPO_ROOT/home/.config/VSCodium/User/settings.json" \
  > "$TMP_WORK/vscodium-settings.json"
install -m0644 "$TMP_WORK/vscodium-settings.json" \
  "$REPO_ROOT/home/.config/VSCodium/User/settings.json"

log "Writing sanitized Codex and VSCodium machine configuration"
mkdir -p -- "$REPO_ROOT/home/.codex" "$REPO_ROOT/home/.vscode-oss"
[[ -f "$HOME/.codex/config.toml" ]] || die "Codex config.toml is missing."
awk '/^(model|model_reasoning_effort|service_tier)[[:space:]]*=/' \
  "$HOME/.codex/config.toml" > "$TMP_WORK/codex-config.toml"
printf '%s\n' 'cli_auth_credentials_store = "keyring"' \
  >> "$TMP_WORK/codex-config.toml"
install -m0600 "$TMP_WORK/codex-config.toml" "$REPO_ROOT/home/.codex/config.toml"

printf '%s\n' '{' '  "enable-crash-reporter": false' '}' \
  > "$TMP_WORK/vscodium-argv.json"
install -m0644 "$TMP_WORK/vscodium-argv.json" "$REPO_ROOT/home/.vscode-oss/argv.json"

log "Vendoring the seven enabled GNOME extensions"
current_gnome_major="$(gnome-shell --version | awk '{split($3, version, "."); print version[1]}')"
[[ -n "$current_gnome_major" ]] || die "Could not determine the GNOME Shell major version."

while IFS= read -r uuid; do
  [[ -n "$uuid" && "$uuid" != \#* ]] || continue
  [[ "$uuid" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]] \
    || die "Unsafe GNOME extension UUID: $uuid"
  source_dir="$SOURCE_EXTENSIONS/$uuid"
  metadata="$source_dir/metadata.json"

  [[ -f "$metadata" ]] || die "Extension source is missing: $uuid"
  jq -e --arg major "$current_gnome_major" \
    '."shell-version" | map(tostring) | index($major) != null' \
    "$metadata" >/dev/null \
    || die "$uuid does not declare support for GNOME $current_gnome_major."
done < "$MANIFEST_DIR/gnome-extensions.txt"

live_magic_patch="$SOURCE_EXTENSIONS/dash2dock-lite@icedman.github.com/integrations.js"
grep -Fq 'Main.layoutManager.primaryIndex' "$live_magic_patch" \
  || die "The live Magic Lamp primary-dock fallback patch is missing; refusing to overwrite the known-good bundle."
grep -Fq 'return dockFallback;' "$live_magic_patch" \
  || die "The live Magic Lamp dock-edge fallback patch is missing; refusing to overwrite the known-good bundle."

while IFS= read -r uuid; do
  [[ -n "$uuid" && "$uuid" != \#* ]] || continue
  source_dir="$SOURCE_EXTENSIONS/$uuid"
  target_dir="$REPO_ROOT/gnome/extensions/$uuid"
  [[ ! -L "$target_dir" ]] || die "Refusing to replace symlinked target: $target_dir"

  mkdir -p -- "$target_dir"
  rsync -a --delete --exclude='gschemas.compiled' "$source_dir/" "$target_dir/"
done < "$MANIFEST_DIR/gnome-extensions.txt"

log "Copying the RPM repository definitions actually used by this setup"
mkdir -p -- "$REPO_ROOT/repos"
for repo_name in \
  brave-browser.repo \
  vscodium.repo \
  _copr:copr.fedorainfracloud.org:atim:starship.repo; do
  [[ -f "/etc/yum.repos.d/$repo_name" ]] \
    || die "Required repository file is missing: $repo_name"
  install -m0644 "/etc/yum.repos.d/$repo_name" "$REPO_ROOT/repos/$repo_name"
done

log "Exporting curated GNOME dconf paths"
escaped_home="$(printf '%s' "$HOME" | sed 's/[][\\.^$*|]/\\&/g')"
while IFS='|' read -r dconf_path filename; do
  [[ -n "$dconf_path" && "$dconf_path" != \#* ]] || continue
  [[ "$dconf_path" =~ ^/org/gnome/[A-Za-z0-9_./-]+/$ ]] \
    || die "Unsafe dconf path: $dconf_path"
  [[ "$filename" =~ ^[A-Za-z0-9._-]+\.ini$ ]] \
    || die "Unsafe dconf filename: $filename"
  raw_dump="$TMP_WORK/$filename.raw"
  rendered_dump="$TMP_WORK/$filename"

  dconf dump "$dconf_path" > "$raw_dump" 2>/dev/null \
    || die "Could not export dconf path: $dconf_path"
  sed \
    -e "s|$escaped_home|__HOME__|g" \
    -e '/^night-light-last-coordinates=/d' \
    -e '/^monitor-count=/d' \
    "$raw_dump" > "$rendered_dump"
  install -m0644 "$rendered_dump" "$REPO_ROOT/dconf/$filename"
done < "$REPO_ROOT/dconf/restore.map"

# Blur My Shell defaults several surfaces to enabled even when no dconf key is
# stored. Encode the user's explicit panel-only intent in the portable bundle.
bms_dump="$REPO_ROOT/dconf/extension-blur-my-shell.ini"
awk '
  BEGIN {
    desired["overview"] = "false"
    desired["appfolder"] = "false"
    desired["applications"] = "false"
    desired["panel"] = "true"
    desired["dash-to-dock"] = "false"
    desired["screenshot"] = "false"
    desired["lockscreen"] = "false"
    desired["window-list"] = "false"
    desired["coverflow-alt-tab"] = "false"
  }
  /^\[[^]]+\]$/ {
    section = substr($0, 2, length($0) - 2)
    print
    if (section in desired)
      print "blur=" desired[section]
    next
  }
  /^blur=/ && (section in desired) { next }
  { print }
' "$bms_dump" > "$TMP_WORK/extension-blur-my-shell.ini"
install -m0644 "$TMP_WORK/extension-blur-my-shell.ini" "$bms_dump"

gsettings get org.gnome.shell favorite-apps \
  > "$MANIFEST_DIR/gnome-favorite-apps.gvariant"

log "Recording read-only system inventories"
mkdir -p -- "$REPO_ROOT/inventory"
if command -v rpm >/dev/null 2>&1; then
  rpm -qa --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
    | LC_ALL=C sort > "$REPO_ROOT/inventory/rpm-installed-nevra.txt"

  while IFS= read -r package_name; do
    [[ -n "$package_name" && "$package_name" != \#* ]] || continue
    rpm -q --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
      "$package_name" 2>/dev/null || printf '%s\tNOT_INSTALLED\n' "$package_name"
  done < "$MANIFEST_DIR/rpm-packages.txt" \
    > "$REPO_ROOT/inventory/managed-rpm-versions.txt"
fi

if command -v flatpak >/dev/null 2>&1; then
  flatpak list --app --columns=application,version,branch,origin,installation \
    > "$REPO_ROOT/inventory/flatpak-apps-installed.txt"
  {
    printf '[system]\n'
    flatpak remotes --system --columns=name,title,url
    printf '\n[user]\n'
    flatpak remotes --user --columns=name,title,url
  } > "$REPO_ROOT/inventory/flatpak-remotes.txt"
fi

if command -v dnf5 >/dev/null 2>&1; then
  dnf5 repo list --enabled > "$REPO_ROOT/inventory/dnf-enabled-repositories.txt"
elif command -v dnf >/dev/null 2>&1; then
  dnf repolist --enabled > "$REPO_ROOT/inventory/dnf-enabled-repositories.txt"
fi

{
  sed -n -e '/^NAME=/p' -e '/^VERSION=/p' -e '/^ID=/p' -e '/^VERSION_ID=/p' \
    /etc/os-release
  gnome-shell --version
  printf 'Kernel %s\n' "$(uname -r)"
  printf 'Login shell %s\n' "$(getent passwd "$(id -un)" | cut -d: -f7)"
} > "$REPO_ROOT/inventory/system-summary.txt"

if command -v gnome-extensions >/dev/null 2>&1; then
  if ! gnome-extensions list --enabled 2>/dev/null | LC_ALL=C sort \
    > "$REPO_ROOT/inventory/gnome-extensions-enabled.txt"; then
    cp -- "$MANIFEST_DIR/gnome-extensions.txt" \
      "$REPO_ROOT/inventory/gnome-extensions-enabled.txt"
  fi
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user list-unit-files --state=enabled --no-legend 2>/dev/null \
    > "$REPO_ROOT/inventory/systemd-user-enabled.txt" || true
fi

if ((INCLUDE_MONITOR_LAYOUT)); then
  source_monitor="$HOME/.config/monitors.xml"
  [[ -f "$source_monitor" ]] || die "No monitors.xml exists on this machine."
  install -Dm0600 "$source_monitor" \
    "$REPO_ROOT/optional/device-specific/monitors.xml"
  printf 'Stored hardware-specific monitors.xml; installer will still ignore it by default.\n'
fi

log "Updating snapshot compatibility metadata"
fedora_major="$(. /etc/os-release; printf '%s' "$VERSION_ID")"
sed -i \
  -e "s/^SNAPSHOT_FEDORA_MAJOR=.*/SNAPSHOT_FEDORA_MAJOR=$fedora_major/" \
  -e "s/^SNAPSHOT_GNOME_MAJOR=.*/SNAPSHOT_GNOME_MAJOR=$current_gnome_major/" \
  "$MANIFEST_DIR/system.env"

log "Generating payload checksums"
checksum_tmp="$TMP_WORK/SHA256SUMS"
(
  cd -- "$REPO_ROOT"
  find dconf gnome home manifests repos -type f ! -name gschemas.compiled -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum
) > "$checksum_tmp"
install -m0644 "$checksum_tmp" "$REPO_ROOT/inventory/SHA256SUMS"

if [[ -x "$REPO_ROOT/scripts/audit.sh" ]]; then
  "$REPO_ROOT/scripts/audit.sh"
fi

log "Snapshot refreshed safely"
printf 'Repository: %s\n' "$REPO_ROOT"
printf 'Review git diff before committing or pushing it.\n'
