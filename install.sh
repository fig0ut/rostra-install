#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install published fig0ut/rostra binaries on Linux with systemd.

REPOSITORY=fig0ut/rostra
API=https://api.github.com/repos/$REPOSITORY
BIN=/usr/local/bin/rostra
UNIT=/etc/systemd/system/rostra.service
CONFIG=/etc/rostra
DATA=/var/lib/rostra
RECEIPT_DIR=/var/lib/rostra-install
RECEIPT=$RECEIPT_DIR/receipt.json
SERVICE=rostra.service
WORK=
TRANSACTION=0
WAS_ACTIVE=0
HAD_INSTALL=0
CREATED_CONFIG=0
CREATED_DATA=0

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sudo bash install.sh <install|update|remove> [options]
   or: curl -fsSL https://raw.githubusercontent.com/fig0ut/rostra-install/main/install.sh | sudo bash -s -- <action> [options]

  install                 Install the latest stable release.
  update                  Update an installation made by this script.
  remove                  Remove the binary/service; keep configuration and data.

  --prerelease            Select the most recently published prerelease.
  --stable                Select GitHub's latest stable release.
  --version VERSION       Select a published tag (with or without leading v).
  --purge                 With remove, also delete /etc/rostra and /var/lib/rostra.
  -h, --help              Show this help.

Updates remember the installed stable/prerelease channel unless overridden.
Requires Linux, root, Bash and a running systemd. Missing prerequisites
(curl, jq, CA certificates, GNU tar, gzip, coreutils and flock) are installed
automatically using apt-get, dnf, yum, zypper or pacman.
New installations are enabled at boot but left stopped until configured.
Updates restart an already running service and roll back on startup failure.
EOF
}

# JSON remains structured; release metadata is never evaluated as shell code.
metadata() {
    local mode=$1
    shift
    case $mode in
        count)
            jq -er 'if type == "array" then length else error("expected a GitHub API list") end' "$1"
            ;;
        prerelease)
            jq -es 'add | map(select(.draft == false and .prerelease == true and .published_at != null))
                | max_by([.published_at, .id]) // error("no published prerelease found")' \
                "$1"/releases.*.json > "$1/release.json"
            ;;
        release)
            jq -er '
                if (.tag_name | type != "string") then error("missing release tag")
                elif (.tag_name | test("\\Av[0-9]+\\.[0-9]+\\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9.-]*)?(\\+[A-Za-z0-9.-]+)?\\z") | not)
                    then error("unsupported release tag")
                elif .draft != false then error("draft releases cannot be installed")
                elif (.id | type != "number") then error("invalid release ID")
                elif .id <= 0 or .id != (.id | floor) then error("invalid release ID")
                elif (.prerelease | type != "boolean") then error("missing release channel")
                else [.id, .tag_name, (if .prerelease then "prerelease" else "stable" end)] | @tsv end
            ' "$1"
            ;;
        asset)
            jq -ers --arg tag "$2" --arg arch "$3" --arg repository "$4" '
                add as $assets
                | ("rostra-" + ($tag | ltrimstr("v")) + "-linux-" + $arch) as $base
                | [$base + "-musl.tar.gz",
                   (if $arch == "amd64" or $arch == "arm64" then empty else $base + ".tar.gz" end)]
                | map(. as $name | [$assets[] | select(.name == $name and .state == "uploaded")])
                | map(if length > 1 then error("ambiguous release assets") else . end)
                | add | .[0] // error("no supported static Linux asset for " + $arch)
                | if (.digest | type != "string") then error("asset has no GitHub SHA-256 digest")
                  elif (.digest | test("\\Asha256:[0-9a-fA-F]{64}\\z") | not)
                    then error("invalid GitHub SHA-256 digest") else . end
                | ("https://github.com/" + $repository + "/releases/download/") as $prefix
                | if .browser_download_url != ($prefix + $tag + "/" + .name)
                     and .browser_download_url != ($prefix + ($tag | @uri) + "/" + (.name | @uri))
                    then error("unexpected asset download URL") else . end
                | if (.size | type != "number") then error("invalid asset size")
                  elif .size <= 0 or .size > 1073741824 or .size != (.size | floor)
                    then error("invalid asset size") else . end
                | [.name, .browser_download_url, (.digest | ascii_downcase), .size] | @tsv
            ' "$1"/assets.*.json
            ;;
        extract) extract_binary "$@" ;;
        channel)
            jq -er 'if .repository != "fig0ut/rostra" or .installer != "rostra-install-v1"
                    then error("unrecognized installer receipt")
                elif .channel != "stable" and .channel != "prerelease"
                    then error("invalid saved release channel") else .channel end' "$1"
            ;;
        receipt)
            jq -n --arg tag "$2" --arg channel "$3" --arg asset "$4" --arg digest "$5" \
                '{installer: "rostra-install-v1", repository: "fig0ut/rostra",
                  tag: $tag, channel: $channel, asset: $asset, digest: $digest}' > "$1"
            ;;
        *) die "Unknown metadata operation: $mode" ;;
    esac
}

extract_binary() {
    local archive=$1 name=$2 digest=$3 size=$4 output=$5 hash member listing extracted_size
    [[ $(stat -c %s -- "$archive") == "$size" ]] || die 'Download size does not match GitHub metadata.'
    hash=$(sha256sum -- "$archive")
    [[ sha256:${hash%% *} == "$digest" ]] || die 'SHA-256 checksum mismatch; installation aborted.'
    member=${name%.tar.gz}/rostra
    # Inspect exactly one regular member, then stream it into a fixed filename.
    # No archive paths, links, ownership or mode bits are extracted to disk.
    listing=$(LC_ALL=C tar --list --verbose --gzip --file "$archive" \
        --no-recursion --no-wildcards -- "$member")
    [[ $listing == -* && $listing != *$'\n'* ]] || die 'Archive must contain one regular rostra binary.'
    [[ ! -e $output && ! -L $output ]] || die 'Extraction destination already exists.'
    tar --extract --gzip --to-stdout --file "$archive" \
        --no-recursion --no-wildcards -- "$member" > "$output"
    extracted_size=$(stat -c %s -- "$output")
    (( extracted_size > 0 && extracted_size <= 1073741824 )) || die 'Invalid extracted binary size.'
    chmod 755 "$output"
}

have_command() { command -v "$1" >/dev/null 2>&1; }

have_ca_certificates() {
    local bundle
    for bundle in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
        /etc/ssl/ca-bundle.pem /etc/ssl/cert.pem; do
        [[ ! -s $bundle ]] || return 0
    done
    return 1
}

install_packages() {
    say "Installing missing prerequisites: $*"
    if have_command apt-get; then
        apt-get update || die 'apt-get update failed; check repository/network access and retry.'
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" || die 'Prerequisite installation failed.'
    elif have_command dnf; then
        dnf install -y "$@" || die 'Prerequisite installation failed.'
    elif have_command yum; then
        yum install -y "$@" || die 'Prerequisite installation failed.'
    elif have_command zypper; then
        zypper --non-interactive install --no-recommends "$@" || die 'Prerequisite installation failed.'
    elif have_command pacman; then
        # Never refresh databases alone (-Sy), which can cause a partial upgrade.
        pacman -S --needed --noconfirm "$@" || die 'Prerequisite installation failed. Update Arch with pacman -Syu, then retry.'
    else
        die "No supported package manager found. Install these packages manually: $*"
    fi
}

ensure_dependencies() {
    local action=$1 command package tar_version
    local -a required=(flock mktemp install mv cp rm chmod sleep dirname cat rmdir)
    local -a packages=()
    local -A seen=()
    if [[ $action != remove ]]; then
        required+=(curl jq sha256sum stat tar gzip)
    fi
    for command in "${required[@]}"; do
        if ! have_command "$command"; then
            case $command in
                flock) package=util-linux ;;
                curl|jq|tar|gzip) package=$command ;;
                *) package=coreutils ;;
            esac
            if [[ ! ${seen[$package]:-} ]]; then
                packages+=("$package")
                seen[$package]=1
            fi
        fi
    done
    if [[ $action != remove ]] && ! have_ca_certificates; then
        packages+=(ca-certificates)
    fi
    if (( ${#packages[@]} )); then
        install_packages "${packages[@]}"
        hash -r
    fi
    for command in "${required[@]}"; do
        have_command "$command" || die "Required command still missing after package installation: $command"
    done
    if [[ $action != remove ]]; then
        have_ca_certificates || die 'No CA certificate bundle found after package installation.'
        tar_version=$(tar --version)
        [[ $tar_version == *'GNU tar'* ]] || die 'GNU tar is required; install your distribution tar package.'
    fi
}

require_system() {
    [[ $(uname -s) == Linux ]] || die 'Only Linux is supported.'
    [[ $EUID == 0 ]] || die 'Run this script as root (sudo bash install.sh ...).'
    have_command systemctl && [[ -d /run/systemd/system ]] || die 'systemd must already be running as the system service manager.'
}

architecture() {
    case $(uname -m) in
        x86_64) say amd64 ;;
        i?86) say 386 ;;
        aarch64|arm64) say arm64 ;;
        armv7*) say armv7 ;;
        armv6*) say armv6 ;;
        armv5*) say armv5 ;;
        ppc64le|s390x|riscv64) uname -m ;;
        loongarch64) say loong64 ;;
        *) die "Unsupported CPU architecture: $(uname -m)" ;;
    esac
}

api_get() {
    # Public metadata needs no token. Do not forward credentials to asset CDNs.
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 120 --retry 3 \
        -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
        "$API/$1" -o "$2"
}

fetch_pages() {
    local endpoint=$1 prefix=$2 page=1 count
    while :; do
        api_get "$endpoint?per_page=100&page=$page" "$WORK/$prefix.$page.json"
        count=$(metadata count "$WORK/$prefix.$page.json")
        [[ $count == 100 ]] || break
        page=$((page + 1))
    done
}

select_release() {
    local channel=$1 version=$2
    if [[ -n $version ]]; then
        api_get "releases/tags/$version" "$WORK/release.json" || die "Cannot retrieve $version. Check that it is published and the GitHub API is reachable."
    elif [[ $channel == prerelease ]]; then
        fetch_pages releases releases
        metadata prerelease "$WORK"
    else
        api_get releases/latest "$WORK/release.json" || die 'Cannot retrieve a stable release. If only prereleases exist, use --prerelease; also check network/API limits.'
    fi
}

write_unit() {
    cat <<EOF
[Unit]
Description=Rostra service
Documentation=https://github.com/fig0ut/rostra
Wants=network-online.target
After=network-online.target nss-lookup.target

[Service]
StateDirectory=rostra
WorkingDirectory=$DATA
ExecStart=$BIN -D $DATA -C $CONFIG run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
}

atomic_copy() {
    local source=$1 destination=$2 mode=$3 temporary
    temporary=$(mktemp "${destination}.XXXXXXXX")
    if install -m "$mode" "$source" "$temporary" && mv -fT "$temporary" "$destination"; then
        return 0
    fi
    rm -f -- "$temporary"
    return 1
}

rollback() {
    say 'Installation failed; restoring the previous binary and service state.' >&2
    if (( HAD_INSTALL )); then
        atomic_copy "$WORK/old-binary" "$BIN" 755
        atomic_copy "$WORK/old-receipt" "$RECEIPT" 644
    else
        systemctl disable --now "$SERVICE" >/dev/null 2>&1
        rm -f -- "$BIN" "$UNIT" "$RECEIPT"
        if (( CREATED_CONFIG )); then rm -f -- "$CONFIG/config.json"; fi
        if (( CREATED_DATA )); then rmdir -- "$DATA" 2>/dev/null; fi
    fi
    systemctl daemon-reload
    if (( WAS_ACTIVE )); then
        systemctl restart "$SERVICE" || say "Could not restart the previous version. Check: journalctl -u $SERVICE" >&2
    fi
}

cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    set +e
    if (( TRANSACTION )); then rollback; fi
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    exit "$status"
}

check_ownership() {
    if [[ -f $RECEIPT && -f $BIN && ! -L $BIN && -f $UNIT && ! -L $UNIT ]]; then
        HAD_INSTALL=1
        return
    fi
    [[ ! -e $RECEIPT && ! -L $RECEIPT ]] || die 'Incomplete installer state. Restore the missing binary/unit before retrying.'
    [[ ! -e $BIN && ! -L $BIN && ! -e $UNIT && ! -L $UNIT ]] || die 'An unmanaged Rostra binary/service exists; migrate or remove it before using this installer.'
    local other
    other=$(command -v rostra || true)
    [[ -z $other ]] || die "An existing Rostra executable was found at $other; refusing a conflicting installation."
    [[ $(systemctl show -p LoadState --value "$SERVICE") == not-found ]] || die 'A Rostra service already exists; refusing to overwrite a package/manual installation.'
}

install_release() {
    local action=$1 channel=$2 version=$3 arch release_id tag selected_channel asset url digest size info check_data
    if (( HAD_INSTALL )); then
        selected_channel=$(metadata channel "$RECEIPT")
        channel=${channel:-$selected_channel}
    elif [[ $action == update ]]; then
        die 'No installation managed by this script was found; use install first.'
    fi
    arch=$(architecture)
    select_release "${channel:-stable}" "$version"
    info=$(metadata release "$WORK/release.json")
    IFS=$'\t' read -r release_id tag selected_channel <<< "$info"
    fetch_pages "releases/$release_id/assets" assets
    info=$(metadata asset "$WORK" "$tag" "$arch" "$REPOSITORY")
    IFS=$'\t' read -r asset url digest size <<< "$info"
    say "Downloading $tag ($arch, $selected_channel): $asset"
    curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 600 --retry 3 "$url" -o "$WORK/archive.tar.gz"
    metadata extract "$WORK/archive.tar.gz" "$asset" "$digest" "$size" "$WORK/rostra"
    say 'GitHub SHA-256 digest verified.'
    "$WORK/rostra" version

    # Validate the candidate against the existing configuration before replacement.
    # Empty defaults expose no listeners and contain no shared credentials.
    check_data=$DATA
    if [[ ! -d $DATA ]]; then
        check_data=$WORK/data
        install -d -m 750 "$check_data"
    fi
    if [[ -d $CONFIG ]] && compgen -G "$CONFIG/*.json" >/dev/null; then
        "$WORK/rostra" -D "$check_data" -C "$CONFIG" check
    else
        install -d -m 700 "$WORK/config"
        printf '{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct"}]}\n' > "$WORK/config/config.json"
        "$WORK/rostra" -D "$check_data" -C "$WORK/config" check
    fi
    if (( HAD_INSTALL )); then
        cp -p -- "$BIN" "$WORK/old-binary"
        cp -p -- "$RECEIPT" "$WORK/old-receipt"
    fi
    if systemctl is-active --quiet "$SERVICE"; then WAS_ACTIVE=1; fi
    write_unit > "$WORK/rostra.service"
    metadata receipt "$WORK/receipt.json" "$tag" "$selected_channel" "$asset" "$digest"

    install -d -m 755 "$(dirname "$BIN")" "$(dirname "$UNIT")"
    [[ -d $CONFIG ]] || install -d -m 750 "$CONFIG"
    if [[ ! -d $DATA ]]; then
        install -d -m 750 "$DATA"
        CREATED_DATA=1
    fi
    TRANSACTION=1
    if [[ -f $WORK/config/config.json && ! -e $CONFIG/config.json ]]; then
        CREATED_CONFIG=1
        atomic_copy "$WORK/config/config.json" "$CONFIG/config.json" 600
    fi
    atomic_copy "$WORK/rostra" "$BIN" 755
    # Preserve local service edits and the current enable/disable state on updates.
    if (( ! HAD_INSTALL )); then atomic_copy "$WORK/rostra.service" "$UNIT" 644; fi
    atomic_copy "$WORK/receipt.json" "$RECEIPT" 644
    systemctl daemon-reload
    if (( ! HAD_INSTALL )); then systemctl enable "$SERVICE"; fi
    if (( WAS_ACTIVE )); then
        systemctl restart "$SERVICE"
        # Type=simple can report success before a process crashes. Watch initial startup.
        local attempt
        for ((attempt = 0; attempt < 5; attempt++)); do
            sleep 1
            systemctl is-active --quiet "$SERVICE" || die 'The updated service did not stay running.'
        done
    fi
    TRANSACTION=0
    say "Installed $tag. Future updates follow the $selected_channel channel."
    if (( ! WAS_ACTIVE )); then
        say "Service is stopped. Edit $CONFIG/config.json, then run:"
        say "  $BIN -D $DATA -C $CONFIG check"
        say "  systemctl start $SERVICE"
    fi
}

remove_installation() {
    local purge=$1
    (( HAD_INSTALL )) || die 'No installation managed by this script was found.'
    systemctl disable --now "$SERVICE"
    rm -f -- "$BIN" "$UNIT" "$RECEIPT"
    systemctl daemon-reload
    # Drop-ins are user configuration and are deliberately preserved.
    if (( purge )); then
        rm -rf -- "$CONFIG" "$DATA"
        say 'Removed Rostra, its configuration and runtime data.'
    else
        say "Removed Rostra. Configuration in $CONFIG and data in $DATA were preserved."
    fi
}

main() {
    set -Eeuo pipefail
    umask 022
    local action=${1:-} channel='' version='' purge=0
    case $action in
        -h|--help|'') usage; return 0 ;;
        install|update|remove) shift ;;
        *) die "Unknown action: $action (use --help)" ;;
    esac
    while (( $# )); do
        case $1 in
            --stable|--prerelease)
                [[ -z $channel && -z $version ]] || die 'Choose only one of --stable, --prerelease and --version.'
                channel=${1#--} ;;
            --version)
                [[ $# -ge 2 && -z $version && -z $channel ]] || die '--version requires a value and cannot be combined with a channel.'
                version=v${2#v}
                [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9][a-zA-Z0-9.-]*)?(\+[a-zA-Z0-9.-]+)?$ ]] || die 'Invalid version.'
                shift ;;
            --purge) purge=1 ;;
            -h|--help) usage; return 0 ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
    if [[ $action == remove ]]; then
        [[ -z $version && -z $channel ]] || die 'Release options do not apply to remove.'
    else
        (( ! purge )) || die '--purge is only valid with remove.'
    fi
    require_system
    ensure_dependencies "$action"
    install -d -m 755 "$RECEIPT_DIR"
    exec 9>"$RECEIPT_DIR/lock"
    flock -n 9 || die 'Another Rostra installer is running.'
    check_ownership
    WORK=$(mktemp -d /tmp/rostra-install.XXXXXXXX)
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    if [[ $action == remove ]]; then
        remove_installation "$purge"
    else
        install_release "$action" "$channel" "$version"
    fi
}

# BASH_SOURCE is empty when Bash reads a downloaded script from standard input.
# Keep sourcing available, and prevent child commands from consuming script input.
if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@" </dev/null
fi
