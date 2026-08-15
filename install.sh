#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly MANIFEST_DIR="$REPO_ROOT/manifests"
readonly SOURCE_HOME="$REPO_ROOT/home"
readonly SOURCE_EXTENSIONS="$REPO_ROOT/gnome/extensions"

# shellcheck source=/dev/null
source "$MANIFEST_DIR/system.env"

DRY_RUN=0
SKIP_PACKAGES=0
SKIP_FLATPAK=0
SKIP_FONT=0
PRUNE_DEFAULT_APPS=0
WITH_MONITOR_LAYOUT=0
ASSUME_YES=0
TMP_WORK=""
BACKUP_DIR=""
EXTENSIONS_RESTORED=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --dry-run                 Show planned actions without changing the machine.
  --skip-packages           Do not configure RPM repos or install RPM packages.
  --skip-flatpak            Do not configure Flathub or install Flatpak apps.
  --skip-font               Do not download JetBrainsMono Nerd Font.
  --prune-default-apps      Remove Fedora default apps absent on the source machine.
  --with-monitor-layout     Restore the source machine's hardware-specific monitors.xml.
  --yes                     Do not prompt for --prune-default-apps.
  -h, --help                Show this help.

Run this script as the desktop user, never with sudo. It invokes sudo only for
RPM, Flatpak and login-shell changes.
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

print_command() {
  printf '  +'
  printf ' %q' "$@"
  printf '\n'
}

run() {
  if ((DRY_RUN)); then
    print_command "$@"
  else
    "$@"
  fi
}

run_root() {
  run sudo "$@"
}

assert_safe_home_target() {
  local relative_path="$1"
  local current_path="$HOME" component
  local -a path_components=()

  [[ "$relative_path" != /* && "$relative_path" != *'..'* ]] \
    || die "Unsafe target path: $relative_path"
  IFS='/' read -r -a path_components <<< "$relative_path"
  for component in "${path_components[@]}"; do
    current_path="$current_path/$component"
    [[ ! -L "$current_path" ]] \
      || die "Refusing to write through a symlinked target: $current_path"
  done
}

verify_bundle_checksums() {
  local checksum_file="$REPO_ROOT/inventory/SHA256SUMS"
  [[ -f "$checksum_file" ]] || die "Missing payload checksum manifest: $checksum_file"

  log "Verifying snapshot payload checksums"
  (cd -- "$REPO_ROOT" && sha256sum --check --quiet "inventory/SHA256SUMS") \
    || die "Snapshot checksum verification failed. Run scripts/snapshot.sh after intentional edits."
}

cleanup() {
  if [[ -n "$TMP_WORK" && -d "$TMP_WORK" ]]; then
    rm -rf -- "$TMP_WORK"
  fi
}

trap cleanup EXIT
trap 'printf "ERROR: install failed at line %s.\n" "$LINENO" >&2' ERR

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --skip-packages) SKIP_PACKAGES=1 ;;
    --skip-flatpak) SKIP_FLATPAK=1 ;;
    --skip-font) SKIP_FONT=1 ;;
    --prune-default-apps) PRUNE_DEFAULT_APPS=1 ;;
    --with-monitor-layout) WITH_MONITOR_LAYOUT=1 ;;
    --yes) ASSUME_YES=1 ;;
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

((EUID != 0)) || die "Do not run the whole installer as root. Run ./install.sh as your user."
[[ -r /etc/os-release ]] || die "Cannot identify the operating system."

# shellcheck source=/dev/null
source /etc/os-release
[[ "${ID:-}" == "fedora" ]] || die "This snapshot targets Fedora Workstation, not ${ID:-unknown}."
[[ "${VARIANT_ID:-}" == "workstation" ]] \
  || die "This snapshot requires Fedora Workstation; detected ${VARIANT:-${VARIANT_ID:-unknown variant}}."

readonly PASSWD_HOME="$(getent passwd "$(id -un)" | cut -d: -f6)"
[[ "$HOME" == "$PASSWD_HOME" ]] \
  || die "HOME ($HOME) does not match the passwd home for $(id -un) ($PASSWD_HOME)."

if [[ "${VERSION_ID:-}" != "$SNAPSHOT_FEDORA_MAJOR" ]]; then
  warn "Snapshot came from Fedora $SNAPSHOT_FEDORA_MAJOR; target is Fedora ${VERSION_ID:-unknown}."
  warn "Packages may still install, but the GNOME bundle is independently version-checked."
fi

TMP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/fedora-dotfiles.XXXXXX")"
readonly TARGET_USER="$(id -un)"

detect_gnome_major() {
  if ! command -v gnome-shell >/dev/null 2>&1; then
    return 0
  fi
  gnome-shell --version | awk '{split($3, version, "."); print version[1]}'
}

preflight_desktop() {
  local gnome_major
  gnome_major="$(detect_gnome_major)"
  [[ -n "$gnome_major" ]] || die "GNOME Shell is missing; install Fedora Workstation first."
  [[ "$gnome_major" == "$SNAPSHOT_GNOME_MAJOR" ]] \
    || die "Extension bundle requires GNOME $SNAPSHOT_GNOME_MAJOR; target is GNOME $gnome_major. Refresh the bundle before upgrading Fedora."

  command -v gsettings >/dev/null 2>&1 || die "gsettings is missing."
  gsettings list-schemas | grep -qx org.gnome.shell \
    || die "The org.gnome.shell settings schema is unavailable."
}

install_rpm_packages() {
  ((SKIP_PACKAGES == 0)) || return 0

  log "Configuring the three RPM repositories used by this setup"
  local repo
  for repo in "$REPO_ROOT"/repos/*.repo; do
    [[ -f "$repo" ]] || continue
    [[ ! -L "/etc/yum.repos.d/$(basename -- "$repo")" ]] \
      || die "Refusing to overwrite a symlinked RPM repository file."
    run_root install -Dm0644 "$repo" "/etc/yum.repos.d/$(basename -- "$repo")"
  done

  local dnf_cmd=""
  if command -v dnf5 >/dev/null 2>&1; then
    dnf_cmd="dnf5"
  elif command -v dnf >/dev/null 2>&1; then
    dnf_cmd="dnf"
  else
    die "Neither dnf5 nor dnf is available."
  fi

  local -a packages=()
  mapfile -t packages < <(
    sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
      "$MANIFEST_DIR/rpm-packages.txt"
  )

  log "Installing ${#packages[@]} RPM packages"
  run_root "$dnf_cmd" install -y "${packages[@]}"

  if ((DRY_RUN == 0)); then
    rpm -q "${packages[@]}" >/dev/null \
      || die "One or more managed RPM packages failed post-install verification."
  fi
}

install_flatpak_apps() {
  ((SKIP_FLATPAK == 0)) || return 0

  if ! command -v flatpak >/dev/null 2>&1; then
    if ((DRY_RUN)); then
      warn "Flatpak is not present yet; the RPM phase would install it."
      print_command sudo flatpak remote-add --system --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo
      local -a planned_apps=()
      mapfile -t planned_apps < <(
        sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
          "$MANIFEST_DIR/flatpak-apps.txt"
      )
      ((${#planned_apps[@]} == 0)) \
        || print_command sudo flatpak install --system -y flathub "${planned_apps[@]}"
      return 0
    fi
    die "Flatpak is missing. Do not combine --skip-packages with Flatpak restore on a minimal target."
  fi

  log "Configuring Flathub and installing Flatpak applications"
  if flatpak remotes --system --columns=name | grep -qx flathub; then
    run_root flatpak remote-modify --system --enable --no-filter \
      --url=https://dl.flathub.org/repo/ flathub
  else
    run_root flatpak remote-add --system --if-not-exists flathub \
      https://dl.flathub.org/repo/flathub.flatpakrepo
  fi

  local -a apps=()
  mapfile -t apps < <(
    sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
      "$MANIFEST_DIR/flatpak-apps.txt"
  )
  ((${#apps[@]} == 0)) || run_root flatpak install --system -y flathub "${apps[@]}"

  if ((DRY_RUN == 0)); then
    local app_id
    for app_id in "${apps[@]}"; do
      flatpak info --system "$app_id" >/dev/null \
        || die "Flatpak application did not install: $app_id"
    done
  fi
}

backup_target() {
  local relative_path="$1"
  local source_path="$HOME/$relative_path"
  local backup_path="$BACKUP_DIR/$relative_path"

  [[ -e "$source_path" || -L "$source_path" ]] || return 0

  if ((DRY_RUN)); then
    printf '  would back up %s\n' "$source_path"
    return 0
  fi

  mkdir -p -- "$(dirname -- "$backup_path")"
  cp -a -- "$source_path" "$backup_path"
}

backup_managed_state() {
  local backup_root="$HOME/.local/state/fedora-dotfiles/backups"
  if ((DRY_RUN)); then
    BACKUP_DIR="$backup_root/DRY-RUN"
  else
    mkdir -p -- "$backup_root"
    BACKUP_DIR="$(mktemp -d "$backup_root/$(date +%Y%m%d-%H%M%S).XXXXXX")"
  fi
  log "Backing up managed targets to $BACKUP_DIR"

  local relative_path
  while IFS= read -r relative_path; do
    [[ -n "$relative_path" && "$relative_path" != \#* ]] || continue
    backup_target "$relative_path"
  done < "$MANIFEST_DIR/managed-home-paths.txt"

  backup_target ".local/share/fonts/JetBrainsMonoNerd"

  local uuid
  while IFS= read -r uuid; do
    [[ -n "$uuid" && "$uuid" != \#* ]] || continue
    backup_target ".local/share/gnome-shell/extensions/$uuid"
  done < "$MANIFEST_DIR/gnome-extensions.txt"

  if ((WITH_MONITOR_LAYOUT)); then
    backup_target ".config/monitors.xml"
  fi

  local repo_name source_repo backup_repo
  for repo_name in \
    brave-browser.repo \
    vscodium.repo \
    _copr:copr.fedorainfracloud.org:atim:starship.repo; do
    source_repo="/etc/yum.repos.d/$repo_name"
    [[ -f "$source_repo" ]] || continue
    backup_repo="$BACKUP_DIR/system/etc/yum.repos.d/$repo_name"
    if ((DRY_RUN)); then
      printf '  would back up %s\n' "$source_repo"
    else
      mkdir -p -- "$(dirname -- "$backup_repo")"
      cp -a -- "$source_repo" "$backup_repo"
    fi
  done

  if ((DRY_RUN)); then
    printf '  would back up managed dconf paths and the current login shell\n'
    return 0
  fi

  mkdir -p -- "$BACKUP_DIR/dconf"
  local dconf_path filename
  while IFS='|' read -r dconf_path filename; do
    [[ -n "$dconf_path" && "$dconf_path" != \#* ]] || continue
    [[ "$dconf_path" =~ ^/org/gnome/[A-Za-z0-9_./-]+/$ ]] \
      || die "Unsafe dconf path in backup map: $dconf_path"
    [[ "$filename" =~ ^[A-Za-z0-9._-]+\.ini$ ]] \
      || die "Unsafe dconf filename in backup map: $filename"
    dconf dump "$dconf_path" > "$BACKUP_DIR/dconf/$filename" 2>/dev/null \
      || die "Could not back up dconf path: $dconf_path"
  done < "$REPO_ROOT/dconf/restore.map"

  {
    printf 'login-shell=%s\n' "$(getent passwd "$TARGET_USER" | cut -d: -f7)"
    if command -v gsettings >/dev/null 2>&1; then
      printf 'favorite-apps=%s\n' "$(gsettings get org.gnome.shell favorite-apps)"
      printf 'enabled-extensions=%s\n' "$(gsettings get org.gnome.shell enabled-extensions)"
      printf 'disabled-extensions=%s\n' "$(gsettings get org.gnome.shell disabled-extensions)"
      printf 'disable-user-extensions=%s\n' "$(gsettings get org.gnome.shell disable-user-extensions)"
      if gsettings list-keys org.gnome.shell | grep -qx 'disable-extension-version-validation'; then
        printf 'disable-extension-version-validation=%s\n' \
          "$(gsettings get org.gnome.shell disable-extension-version-validation)"
      fi
    fi
  } > "$BACKUP_DIR/pre-bootstrap-state.txt"
}

restore_home_payload() {
  log "Restoring curated home configuration"

  local relative_path source_path target_path
  while IFS= read -r relative_path; do
    [[ -n "$relative_path" && "$relative_path" != \#* ]] || continue
    [[ "$relative_path" != /* && "$relative_path" != *'..'* ]] \
      || die "Unsafe managed home path: $relative_path"

    source_path="$SOURCE_HOME/$relative_path"
    target_path="$HOME/$relative_path"
    [[ -e "$source_path" || -L "$source_path" ]] \
      || die "Managed payload is missing: $relative_path"

    assert_safe_home_target "$relative_path"

    if [[ -d "$source_path" ]]; then
      run mkdir -p -- "$target_path"
      run rsync -a "$source_path/" "$target_path/"
    else
      run mkdir -p -- "$(dirname -- "$target_path")"
      run rsync -a "$source_path" "$target_path"
    fi
  done < "$MANIFEST_DIR/managed-home-paths.txt"

  if ((DRY_RUN == 0)) && [[ -f "$HOME/.codex/config.toml" ]]; then
    chmod 0600 "$HOME/.codex/config.toml"
  fi
}

restore_custom_sound_links() {
  local sound_dir="$HOME/.local/share/sounds/__custom"
  local click_sound="/usr/share/sounds/gnome/default/alerts/click.ogg"
  [[ -e "$click_sound" ]] \
    || die "GNOME click sound is missing; cannot build the custom sound theme."

  log "Recreating portable custom-sound links"
  [[ ! -d "$sound_dir/bell-terminal.ogg" && ! -d "$sound_dir/bell-window-system.ogg" ]] \
    || die "A custom-sound link target is unexpectedly a directory."
  run mkdir -p -- "$sound_dir"
  run ln -sfn -- "$click_sound" "$sound_dir/bell-terminal.ogg"
  run ln -sfn -- "$click_sound" "$sound_dir/bell-window-system.ogg"
}

install_nerd_font() {
  ((SKIP_FONT == 0)) || return 0

  local font_dir="$HOME/.local/share/fonts/JetBrainsMonoNerd"
  assert_safe_home_target ".local/share/fonts/JetBrainsMonoNerd"
  local marker="$font_dir/.nerd-fonts-version-$NERD_FONT_VERSION"
  if [[ -f "$marker" ]]; then
    log "JetBrainsMono Nerd Font $NERD_FONT_VERSION is already installed"
    return 0
  fi

  log "Installing pinned JetBrainsMono Nerd Font $NERD_FONT_VERSION"
  local archive="$TMP_WORK/JetBrainsMono.zip"
  if ((DRY_RUN)); then
    print_command curl --fail --location --retry 3 --output "$archive" "$NERD_FONT_URL"
    print_command unzip -oq "$archive" -d "$font_dir"
    print_command fc-cache -f "$HOME/.local/share/fonts"
    return 0
  fi

  curl --fail --location --retry 3 --output "$archive" "$NERD_FONT_URL"
  printf '%s  %s\n' "$NERD_FONT_SHA256" "$archive" | sha256sum --check --status \
    || die "Nerd Font checksum verification failed."

  mkdir -p -- "$font_dir"
  unzip -oq "$archive" -d "$font_dir"
  printf '%s\n' "$NERD_FONT_VERSION" > "$marker"
  fc-cache -f "$HOME/.local/share/fonts"
}

restore_extensions() {
  local gnome_major
  gnome_major="$(detect_gnome_major)"

  if [[ -z "$gnome_major" ]]; then
    warn "GNOME Shell is unavailable; skipping extension installation."
    return 0
  fi

  if [[ "$gnome_major" != "$SNAPSHOT_GNOME_MAJOR" ]]; then
    warn "Extension bundle targets GNOME $SNAPSHOT_GNOME_MAJOR; target is GNOME $gnome_major."
    warn "Skipping extension sources and enablement to avoid loading incompatible code."
    return 0
  fi

  log "Restoring vendored GNOME Shell extensions for Shell $gnome_major"
  local extension_root="$HOME/.local/share/gnome-shell/extensions"
  assert_safe_home_target ".local/share/gnome-shell/extensions"
  run mkdir -p -- "$extension_root"

  local uuid source_dir target_dir metadata
  while IFS= read -r uuid; do
    [[ -n "$uuid" && "$uuid" != \#* ]] || continue
    [[ "$uuid" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]] \
      || die "Unsafe GNOME extension UUID: $uuid"
    source_dir="$SOURCE_EXTENSIONS/$uuid"
    target_dir="$extension_root/$uuid"
    metadata="$source_dir/metadata.json"

    [[ -f "$metadata" ]] || die "Missing metadata for vendored extension: $uuid"
    assert_safe_home_target ".local/share/gnome-shell/extensions/$uuid"
    [[ ! -L "$target_dir" ]] || die "Refusing to replace symlinked extension target: $target_dir"
    if command -v jq >/dev/null 2>&1; then
      if ! jq -e --arg major "$gnome_major" \
        '."shell-version" | map(tostring) | index($major) != null' \
        "$metadata" >/dev/null; then
        die "$uuid does not declare support for GNOME $gnome_major."
      fi
    elif ((DRY_RUN)); then
      warn "jq is not present yet; skipping metadata JSON validation in dry-run."
    else
      die "jq is required to validate extension metadata."
    fi

    if command -v gnome-extensions >/dev/null 2>&1 \
      && gnome-extensions info "$uuid" >/dev/null 2>&1; then
      if ((DRY_RUN)); then
        print_command gnome-extensions disable "$uuid"
      elif ! gnome-extensions disable "$uuid"; then
        warn "Could not disable $uuid before replacing its files; log out before rerunning."
      fi
    elif command -v gnome-extensions >/dev/null 2>&1; then
      warn "Could not query $uuid in the current session; its new files take effect after logout."
    fi

    run mkdir -p -- "$target_dir"
    run rsync -a --delete "$source_dir/" "$target_dir/"

    if find "$source_dir/schemas" -maxdepth 1 -type f -name '*.xml' \
      -print -quit 2>/dev/null | grep -q .; then
      run glib-compile-schemas --strict "$target_dir/schemas"
    fi
  done < "$MANIFEST_DIR/gnome-extensions.txt"

  EXTENSIONS_RESTORED=1
}

load_dconf_file() {
  local dconf_path="$1"
  local source_file="$2"

  [[ -s "$source_file" ]] || die "Missing or empty dconf payload: $source_file"
  if ((DRY_RUN)); then
    print_command dconf reset -f "$dconf_path"
    printf '  would load %s into %s\n' "$source_file" "$dconf_path"
    return 0
  fi

  local escaped_home="$HOME"
  escaped_home="${escaped_home//\\/\\\\}"
  escaped_home="${escaped_home//&/\\&}"
  escaped_home="${escaped_home//|/\\|}"

  local rendered
  rendered="$(mktemp "$TMP_WORK/dconf.XXXXXX")"
  sed "s|__HOME__|$escaped_home|g" "$source_file" > "$rendered"
  dconf reset -f "$dconf_path"
  dconf load "$dconf_path" < "$rendered"
}

restore_dconf() {
  command -v dconf >/dev/null 2>&1 || die "dconf is required to restore GNOME settings."

  log "Restoring portable GNOME and extension settings"
  local dconf_path filename
  while IFS='|' read -r dconf_path filename; do
    [[ -n "$dconf_path" && "$dconf_path" != \#* ]] || continue
    [[ "$dconf_path" =~ ^/org/gnome/[A-Za-z0-9_./-]+/$ ]] \
      || die "Unsafe dconf path: $dconf_path"
    [[ "$filename" =~ ^[A-Za-z0-9._-]+\.ini$ ]] \
      || die "Unsafe dconf filename: $filename"
    load_dconf_file "$dconf_path" "$REPO_ROOT/dconf/$filename"
  done < "$REPO_ROOT/dconf/restore.map"

  command -v gsettings >/dev/null 2>&1 || return 0

  local favorites
  favorites="$(tr -d '\n' < "$MANIFEST_DIR/gnome-favorite-apps.gvariant")"
  run gsettings set org.gnome.shell favorite-apps "$favorites"
  run gsettings set org.gnome.shell disable-user-extensions false
  if gsettings list-keys org.gnome.shell | grep -qx 'disable-extension-version-validation'; then
    run gsettings set org.gnome.shell disable-extension-version-validation false
  fi
  run gsettings set org.gnome.shell disabled-extensions \
    "['background-logo@fedorahosted.org']"

  if ((EXTENSIONS_RESTORED)); then
    local enabled_extensions
    enabled_extensions="$(tr -d '\n' < "$MANIFEST_DIR/gnome-enabled-extensions.gvariant")"
    run gsettings set org.gnome.shell enabled-extensions "$enabled_extensions"
  fi
}

restore_monitor_layout() {
  ((WITH_MONITOR_LAYOUT)) || return 0
  local source_file="$REPO_ROOT/optional/device-specific/monitors.xml"
  [[ -f "$source_file" ]] || die "Optional monitors.xml is missing."

  warn "Restoring a monitor layout containing source-device connector/EDID identifiers."
  assert_safe_home_target ".config/monitors.xml"
  run install -Dm0644 "$source_file" "$HOME/.config/monitors.xml"
}

install_vscodium_extensions() {
  if ! command -v codium >/dev/null 2>&1; then
    if ((DRY_RUN)); then
      warn "VSCodium is not present yet; the RPM phase would install it."
    else
      die "VSCodium is unavailable after package installation."
    fi
  fi

  log "Installing VSCodium extensions"
  local extension_id
  while IFS= read -r extension_id; do
    [[ -n "$extension_id" && "$extension_id" != \#* ]] || continue
    if ((DRY_RUN)); then
      print_command codium --install-extension "$extension_id" --force
    elif ! codium --install-extension "$extension_id" --force; then
      die "Could not install required VSCodium extension: $extension_id"
    fi
  done < "$MANIFEST_DIR/vscodium-extensions.txt"

  if ((DRY_RUN == 0)); then
    local installed_extensions
    installed_extensions="$(codium --list-extensions)"
    while IFS= read -r extension_id; do
      [[ -n "$extension_id" && "$extension_id" != \#* ]] || continue
      grep -Fxiq "$extension_id" <<< "$installed_extensions" \
        || die "VSCodium extension failed post-install verification: $extension_id"
    done < "$MANIFEST_DIR/vscodium-extensions.txt"
  fi
}

set_login_shell() {
  command -v fish >/dev/null 2>&1 || return 0

  local fish_path current_shell
  fish_path="$(command -v fish)"
  current_shell="$(getent passwd "$TARGET_USER" | cut -d: -f7)"
  [[ "$current_shell" != "$fish_path" ]] || return 0

  log "Setting $fish_path as the login shell for $TARGET_USER"
  run_root usermod --shell "$fish_path" "$TARGET_USER"
}

prune_default_apps() {
  ((PRUNE_DEFAULT_APPS)) || return 0

  if ((ASSUME_YES == 0 && DRY_RUN == 0)); then
    printf '\nRemoving Fedora defaults may remove many dependencies (especially GNOME Boxes).\n'
    read -r -p 'Continue? [y/N] ' answer
    [[ "$answer" =~ ^[Yy]$ ]] || {
      warn "Default-app pruning cancelled."
      return 0
    }
  fi

  local -a packages=()
  mapfile -t packages < <(
    sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
      "$MANIFEST_DIR/pruned-default-apps.txt"
  )
  ((${#packages[@]} == 0)) && return 0

  local dnf_cmd=""
  if command -v dnf5 >/dev/null 2>&1; then
    dnf_cmd="dnf5"
  elif command -v dnf >/dev/null 2>&1; then
    dnf_cmd="dnf"
  else
    die "Neither dnf5 nor dnf is available for default-app pruning."
  fi
  run_root "$dnf_cmd" remove -y "${packages[@]}"
}

verify_snapshot_presence() {
  log "Verifying restored files"
  local uuid
  while IFS= read -r uuid; do
    [[ -n "$uuid" && "$uuid" != \#* ]] || continue
    if ((EXTENSIONS_RESTORED)) && [[ ! -f "$HOME/.local/share/gnome-shell/extensions/$uuid/metadata.json" ]]; then
      die "Extension did not restore correctly: $uuid"
    fi
  done < "$MANIFEST_DIR/gnome-extensions.txt"

  if ((DRY_RUN == 0)) && command -v fc-match >/dev/null 2>&1; then
    printf 'Font match: '
    fc-match 'JetBrainsMono Nerd Font' | head -n 1
  fi
}

log "Fedora dotfiles bootstrap"
printf 'Repository: %s\nTarget user: %s\n' "$REPO_ROOT" "$TARGET_USER"

verify_bundle_checksums
preflight_desktop

if ((DRY_RUN == 0)) && ((SKIP_PACKAGES == 0 || SKIP_FLATPAK == 0)); then
  sudo -v
fi

backup_managed_state
install_rpm_packages
if ((DRY_RUN == 0)); then
  "$REPO_ROOT/scripts/audit.sh"
fi
install_flatpak_apps
restore_home_payload
restore_custom_sound_links
install_nerd_font
restore_extensions
restore_dconf
restore_monitor_layout
install_vscodium_extensions
set_login_shell
prune_default_apps
verify_snapshot_presence

log "Bootstrap complete"
if ((DRY_RUN)); then
  printf 'Dry-run only: no persistent changes were made.\n'
else
  printf 'Backup: %s\n' "$BACKUP_DIR"
  printf 'Log out and back in so Wayland, environment.d, Fish and GNOME extensions reload.\n'
  printf 'Then sign in again to Codex, browsers and GNOME Online Accounts; credentials were not copied.\n'
fi
