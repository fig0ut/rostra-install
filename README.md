# Rostra installer

Install published [Rostra](https://github.com/fig0ut/rostra) releases on Linux
servers running systemd. Requires Bash, root and an already running systemd.
The installer does not use Python. It automatically installs missing prerequisites
(`curl`, `jq`, CA certificates, GNU tar, gzip, coreutils and `flock` from util-linux)
through the system package manager:

| Distribution family | Package manager |
| --- | --- |
| Debian / Ubuntu | apt-get |
| Fedora / RHEL / Rocky / AlmaLinux | dnf or yum |
| openSUSE / SUSE | zypper |
| Arch Linux | pacman |

Packages come from your configured repositories. If installation fails, or the
package manager is unsupported, the script stops with an error. Existing
prerequisites are reused. It does not run a system upgrade; on Arch, stale package
databases may require you to run `pacman -Syu` before retrying. Removing Rostra does
not uninstall shared prerequisite packages or require the download/JSON tools.

## Usage

### Run from a URL

Latest stable release:

```sh
curl -fsSL https://raw.githubusercontent.com/fig0ut/rostra-install/main/install.sh | sudo bash -s -- install
```

Latest prerelease (use this when no stable release exists yet):

```sh
curl -fsSL https://raw.githubusercontent.com/fig0ut/rostra-install/main/install.sh | sudo bash -s -- install --prerelease
```

Replace `install --prerelease` with `update`, `remove`, or any action/options below.
When running as root, omit `sudo`. The initial download requires curl and working
CA certificates; the script installs any remaining missing prerequisites.

You can also download the complete script before running it:

```sh
curl -fsSL https://raw.githubusercontent.com/fig0ut/rostra-install/main/install.sh -o install.sh && sudo bash install.sh install --prerelease
```

### Run a local copy

Run from a local checkout of this repository:

#### Latest stable release

```sh
sudo bash install.sh install
```

#### Latest published prerelease (use this when no stable release exists yet)

```sh
sudo bash install.sh install --prerelease
```

#### A specific published version

```sh
sudo bash install.sh install --version 1.15.0-beta.1
```

#### Update using the channel saved by the previous installation

```sh
sudo bash install.sh update
```

#### Explicitly switch channels

```sh
sudo bash install.sh update --prerelease
```

```sh
sudo bash install.sh update --stable
```

#### Remove binary and service, preserving configuration and data

```sh
sudo bash install.sh remove
```

#### Also delete /etc/rostra and /var/lib/rostra

```sh
sudo bash install.sh remove --purge
```

`--version` selects an exact tag for that operation. Future updates follow that
release's stable/prerelease channel; they are not pinned to the specified tag.
`--prerelease` chooses the prerelease with the latest publication timestamp.
Explicit version/channel changes can downgrade the installed version.

## Configure and start

New installations create a minimal configuration with no listeners or shared
credentials. They enable `rostra.service` for boot but leave it stopped.
Edit `/etc/rostra/config.json` for your deployment, then run:

```sh
sudo /usr/local/bin/rostra -D /var/lib/rostra -C /etc/rostra check
sudo systemctl start rostra
sudo systemctl status rostra
sudo journalctl -u rostra -e
```

The service runs as root, matching Rostra's supplied unit and allowing TUN and
privileged ports. Configuration files and systemd overrides remain under your
control. This installer does not configure firewall rules, TLS certificates,
proxy credentials or automatic updates.

## Installation behavior

- Installs the binary at `/usr/local/bin/rostra` and the unit at
  `/etc/systemd/system/rostra.service`.
- Uses `/etc/rostra` for configuration, `/var/lib/rostra` for runtime data and
  `/var/lib/rostra-install` for the installation receipt and lock.
- Selects static musl builds when available. Uses self-contained unsuffixed
  builds on other supported architectures. Requires musl assets for amd64/arm64;
  their unsuffixed archives contain a separate Cronet library.
- Supports amd64, arm64, 386, ARM v5/v6/v7, ppc64le, s390x, riscv64 and loong64
  when the selected release includes an appropriate asset.
- Checks the downloaded archive's size and SHA-256 against GitHub's release
  asset metadata **before extracting or executing it**. Missing/mismatching
  digests abort installation. No separate checksum file is needed. This verifies
  the download against GitHub's stored asset, not an independent signature.
- Checks the candidate binary and existing configuration before replacement.
  Updates preserve config, data, service edits and the enabled/disabled state.
  Running services restart; stopped services stay stopped. A failed restart or
  failed five-second startup check restores the previous binary and receipt and
  attempts to restart the previous version. This does not undo application data
  changes or detect failures occurring after that startup window.
- Refuses to overwrite package-managed/manual installations. Migrate those
  explicitly before installing; existing configuration directories can be kept.
- Removal preserves systemd drop-ins. Even `--purge` only deletes the named
  configuration/data directories, not external certificates or other user files.
