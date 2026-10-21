#!/usr/bin/env bash

# Install Fortress Controller. Run as yourself (not with sudo); it asks for
# your password for the parts that need root.
#
#   ./install.sh             install or update
#   ./install.sh --uninstall remove everything it installed

set -euo pipefail
cd "$(dirname "$0")"

LIBEXEC=/usr/local/libexec/fortress-controller
CTL=$LIBEXEC/fortressctl
SUDOERS=/etc/sudoers.d/fortress-controller
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Fortress Controller.app"
AGENT="$HOME/Library/LaunchAgents/local.fortress-controller.plist"
ME=$(id -un)

[ "$(id -u)" != 0 ] || { echo "Run this as yourself, not with sudo." >&2; exit 1; }

if [ "${1:-}" = --uninstall ]; then
	pkill -x FortressController 2>/dev/null || true
	rm -rf "$APP" "$AGENT"
	sudo rm -f "$SUDOERS"
	sudo rm -rf "$LIBEXEC"
	echo "Removed Fortress Controller (config backups kept in /opt/local/var/fortress-controller)."
	exit 0
fi

./build.sh

# Root-owned helper: root must own the file and every directory above it,
# or a sudo rule pointing at it could be abused.
sudo install -d -o root -g wheel -m 755 /usr/local/libexec "$LIBEXEC"
sudo install -o root -g wheel -m 755 fortressctl "$CTL"
echo "Installed $CTL"

cat <<EOF

How should the app get root access?
  1) Read-only views without a password, ask for a password to change anything (recommended)
  2) Everything without a password (any program running as $ME could then turn the firewall off)
  3) Always ask for a password (PF stats, the Privoxy log and live views will be limited)
EOF
read -r -p "Choose 1, 2 or 3 [1]: " choice
case ${choice:-1} in
1) RULE="$ME ALL=(root) NOPASSWD: $CTL ro *" ;;
2) RULE="$ME ALL=(root) NOPASSWD: $CTL *" ;;
3) RULE="" ;;
*) echo "Unknown choice" >&2; exit 1 ;;
esac

if [ -n "$RULE" ]; then
	tmp=$(mktemp)
	printf '# Fortress Controller (installed by %s)\n%s\n' "$PWD/install.sh" "$RULE" > "$tmp"
	if sudo visudo -cf "$tmp" >/dev/null; then
		sudo install -o root -g wheel -m 440 "$tmp" "$SUDOERS"
		echo "Installed $SUDOERS"
	else
		echo "sudoers rule failed validation; not installed" >&2
	fi
	rm -f "$tmp"
	sudo -k
	if sudo -n -l "$CTL" ro status >/dev/null 2>&1; then
		echo "Verified: read-only commands run without a password."
	else
		echo "Warning: the sudo rule is not taking effect (is /etc/sudoers.d included?)." >&2
	fi
else
	sudo rm -f "$SUDOERS"
fi

pkill -x FortressController 2>/dev/null || true
mkdir -p "$APP_DIR"
rm -rf "$APP"
cp -R "build/Fortress Controller.app" "$APP"
echo "Installed $APP"

read -r -p "Start Fortress Controller at login? [Y/n]: " login
if [ "${login:-y}" != n ] && [ "${login:-y}" != N ]; then
	mkdir -p "$(dirname "$AGENT")"
	cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>local.fortress-controller</string>
	<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/FortressController</string></array>
	<key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
fi

open "$APP"
echo "Fortress Controller is running in the menu bar (shield icon)."
