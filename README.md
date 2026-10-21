# Fortress Controller

A menu bar app and dashboard for [macOS-Fortress](https://ports.macports.org/port/macos-fortress/), the MacPorts firewall + blocking-proxy bundle (PF firewall, Privoxy, adblock2privoxy, hosts and IP blocklists).

macOS-Fortress runs as a dozen launchd daemons with logs and configs scattered across `/opt/local`. Fortress Controller puts all of it in one place: see what every component is doing, control it, read every log it writes, and get notified when something breaks.

> Not affiliated with macOS-Fortress or MacPorts.

## Features

**Menu bar**
- Shield icon showing overall health: normal, orange (warnings) or red (errors)
- Live component status: system proxy, Privoxy, ad blocking, HTTPS inspection, blackhole server, PAC server, PF
- Turn the system proxy on/off per network service
- Quick actions: restart Privoxy, reload PF, update all blocklists, reload the whole fortress
- Notifications for new problems, resolved problems, newly blocked attackers and blocklist update errors

**Dashboard**

| Tab | What it does |
| --- | --- |
| Overview | End-to-end tests through the proxy (ad host blocked over HTTP and HTTPS, HTTPS inspection, pass-through), problems list, load/unload the whole fortress |
| Services | All 12 launchd jobs with state, PID, last exit code, run count and schedule; start, stop, restart, run now |
| PF Firewall | Enable/disable/reload, the 4 tables with entry and hit counts, view entries, test/block/unblock an IP, flush or expire `bruteforce`, live blocked packets from `pflog0` |
| Blocklists & Privoxy | Age, size and entries of every list; update each feed; re-initialize adblock2privoxy; Privoxy filtering toggle, log levels, certificate cache |
| Logs | Every log macOS-Fortress produces, tail or follow live, with filtering |
| Config files | Edit 11 config files with validation before saving and automatic backups |
| Health check | Runs the port's `macosfortress_setup_check.sh` and `pf_attacks.sh` |

## Requirements

- macOS 13 or later
- [MacPorts](https://www.macports.org) with `macos-fortress` installed
- Xcode or the Command Line Tools (to compile the app with `swiftc`)

## Install

```sh
git clone https://github.com/onemannoplan/fortress-controller.git
cd fortress-controller
./install.sh
```

Run `install.sh` as yourself, not with `sudo`. It asks for your password when it needs root. It:

1. builds `Fortress Controller.app`
2. installs the `fortressctl` helper root-owned at `/usr/local/libexec/fortress-controller/fortressctl`
3. asks how the app gets root access (see [Security model](#security-model))
4. installs the app to `~/Applications` and optionally starts it at login

To remove everything it installed:

```sh
./install.sh --uninstall
```

## How it works

```
Fortress Controller.app  ──►  sudo -n fortressctl …   (if a sudoers rule allows it)
 (menu bar + dashboard)   ──►  fortressctl …           (unprivileged, read-only views)
                          ──►  admin password prompt   (changes, when no rule allows it)
```

- **`fortressctl`** is a bash script that does every privileged operation: `launchctl`, `pfctl`, `port`, `networksetup`, reading root-only logs, installing config files. It only accepts a fixed set of commands and validates every argument (service labels, table names, IP addresses, network service names, log and config names).
- **`FortressController.swift`** is the AppKit app: menu bar item, notifications, status polling and the dashboard window.
- **`dashboard.html`** is the dashboard UI (vanilla JS, no network access), shown in a WKWebView and talking to the app through a message bridge.

The helper can also be used directly:

```sh
fortressctl ro status            # JSON status of everything
fortressctl ro log privoxy 200   # last 200 lines of a log
fortressctl ro follow pflog      # live blocked packets
sudo fortressctl pf reload
sudo fortressctl update all
sudo fortressctl sysproxy on Wi-Fi
```

Run `fortressctl` with no arguments for the full command list.

## Security model

The installer offers three levels of access:

| Option | Without a password | Asks for a password |
| --- | --- | --- |
| 1. Read-only (recommended) | `fortressctl ro …`: status, PF stats, logs, configs | anything that changes the system |
| 2. Everything | all `fortressctl` commands | nothing |
| 3. None | unprivileged views only | everything that needs root |

With option 2, any program running as your user can turn the firewall or proxy off, so it isn't recommended.

Other safeguards:
- `fortressctl` and every directory above it are root-owned, so the sudoers rule can't be redirected to another script.
- The Privoxy `ca-password` is masked when the Privoxy config is read, and restored when it's saved.
- Under `sudo`, `config-install` only accepts source files owned by the calling user, so it can't copy other root-only files somewhere readable.
- Config edits are validated (`pfctl -n`, `privoxy --config-test`, `nginx -t`, `jsc`) and the previous version is backed up to `/opt/local/var/fortress-controller/backups`.

## Logs it reads

| Name | Location |
| --- | --- |
| fortress | `/opt/local/var/log/macos-fortress.log` |
| adblock2privoxy | `/opt/local/var/log/adblock2privoxy.log` |
| privoxy | `/opt/local/var/log/privoxy/logfile` |
| nginx-error / nginx-access | `/opt/local/var/log/nginx/` |
| apache-error / apache-access | `/var/log/apache2/` |
| pflog | live capture of `pflog0` |
| launchd | macOS unified log entries for the fortress daemons |

Privoxy logs only fatal errors unless `debug` levels are set. Use **Blocklists & Privoxy → Privoxy log detail** to log blocked requests (1024) or TLS errors (8192).

## Known macOS-Fortress issues it surfaces

These come from the macOS-Fortress ports, not from this app:

- **`macosfortress_setup_check.sh` false alarms.** The "Privoxy config http://p.p/" and "Blackhole server" checks always fail: the script doesn't export `http_proxy` and doesn't accept the blackhole's self-signed certificate. It also expects a `block.txt.asc` that's never downloaded. The Overview tab runs working versions of these checks.
- **Empty `trustedCAs.pem`.** `privoxy-pki-bundle` builds it with a script that calls `gcsplit`. Without the `coreutils` port, the file ends up empty and Privoxy can't verify any HTTPS site. Fix: `sudo port install coreutils && sudo port -n upgrade --force privoxy-pki-bundle`.
- **CA files not found.** Privoxy looks for `cacert.crt` and `cakey.pem` by default, but the port installs `ca.cert.pem` and `ca.key.pem` and doesn't add `ca-cert-file` / `ca-key-file` to the config. Every inspected HTTPS site fails with `Loading issuer certificate .../cacert.crt failed`. Fix: add `ca-cert-file ca.cert.pem` and `ca-key-file ca.key.pem` to `/opt/local/etc/privoxy/config`.
- **`ca-password` not set.** The `privoxy +https_inspection` port generates an encrypted CA key but leaves `ca-password` out of the Privoxy config. HTTPS inspection fails until it's added.
- **PF rules never load on a fresh install.** At first boot `pf.conf` loads before the blocklist files are downloaded. `pfctl` rejects the whole ruleset, and since the wrapper already ran `pfctl -Fall`, PF is left enabled with no rules. The feed jobs only refresh tables, so nothing recovers it. Fix: Reload PF once the lists exist.
- **World-readable CA key.** The generated `ca.key.pem` is installed with mode `0664`. It should be `600`.
- **yoyo.org hosts list never applied.** In the hosts list builder, the yoyo.org URL contains an unquoted `&`, so the shell splits the command and that list is skipped.

## Development

```sh
./build.sh    # builds build/Fortress Controller.app (ad-hoc signed)
```

Environment variables for testing an uninstalled build:

- `FORTRESSCTL=/path/to/fortressctl` uses that copy of the helper (unprivileged)
- `FC_SELFTEST=/path/to/out.json` opens the dashboard, waits for it to load, writes the rendered text and any JavaScript errors to the file, then quits

```sh
FORTRESSCTL=$PWD/fortressctl FC_SELFTEST=/tmp/selftest.json \
  "build/Fortress Controller.app/Contents/MacOS/FortressController"
```
