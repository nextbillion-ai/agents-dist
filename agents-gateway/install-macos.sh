#!/bin/bash
# Installs or upgrades agents-gateway on macOS (Apple silicon), the same
# setup as the NixOS module: the daemon runs as its own hidden service
# account, which alone can read the GitHub App's private key, and the agents'
# account gets git and gh wrappers first on its PATH.
#
# Run as an admin, from any directory:
#
#   curl -fsSL https://raw.githubusercontent.com/nextbillion-ai/agents-dist/main/agents-gateway/install-macos.sh | sudo bash
#
# It installs the latest release on nextbillion-ai/agents-dist (checking its
# hash). Rerun it to upgrade. Settings are the variables below; override one
# with e.g. `sudo AGENT_USER=other bash install-macos.sh`.
set -euo pipefail

SERVICE=${SERVICE:-nextbillion-agents-gateway}  # account _$SERVICE, launchd label ai.nextbillion.agents-gateway
AGENT_USER=${AGENT_USER:-raft-nextbillion}     # the account the agents run as
APP_ID=${APP_ID:-5724585}                      # GitHub App nb-agents-gateway
INSTALLATION=${INSTALLATION:-nextbillion-ai}
COMMIT_EMAIL=${COMMIT_EMAIL:-agents@nextbillion.ai}
DIST=${DIST:-https://raw.githubusercontent.com/nextbillion-ai/agents-dist/main/agents-gateway}

ACCOUNT=_$SERVICE
LABEL=ai.nextbillion.agents-gateway
PREFIX=/usr/local/$SERVICE                 # bin/agents-gateway, libexec/{git,gh}: root-owned
STATE=/usr/local/var/lib/$SERVICE          # 0700, the account's: github-app-private-key.pem
RUN=/usr/local/var/run/$SERVICE            # 0755, the account's: gateway.sock
LOG=/usr/local/var/log/$SERVICE.log
KEY=$STATE/github-app-private-key.pem
SOCKET=$RUN/gateway.sock
PLIST=/Library/LaunchDaemons/$LABEL.plist

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
[ "$(uname -s)/$(uname -m)" = Darwin/arm64 ] || die "this installer is for macOS on Apple silicon"
id "$AGENT_USER" >/dev/null 2>&1 || die "no account $AGENT_USER"
AGENT_HOME=$(dscl . -read "/Users/$AGENT_USER" NFSHomeDirectory | awk '{print $2}')

# The real programs the wrappers run.
REAL_GIT=/usr/bin/git
REAL_GH=""
for p in /opt/homebrew/bin/gh /usr/local/bin/gh; do
  if [ -x "$p" ]; then REAL_GH=$p; break; fi
done
[ -n "$REAL_GH" ] || die "gh not found (brew install gh)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Latest release"
curl -fsSL "$DIST/release.json" -o "$tmp/release.json"
field() { /usr/bin/plutil -extract "$1" raw -o - "$tmp/release.json"; }
version=$(field version)
url=$(field darwin_arm64.url)
want=$(field darwin_arm64.hash)
say "agents-gateway $version"

curl -fsSL "$url" -o "$tmp/agents-gateway"
got="sha256-$(openssl dgst -sha256 -binary "$tmp/agents-gateway" | base64)"
[ "$got" = "$want" ] || die "hash mismatch: got $got, release.json says $want"
chmod 755 "$tmp/agents-gateway"
"$tmp/agents-gateway" version >/dev/null || die "the downloaded binary does not run"

if ! id "$ACCOUNT" >/dev/null 2>&1; then
  # A hidden service account, like the system's _www: no login, no home,
  # not shown in System Settings. Take a free ID below 500.
  uid=400
  while dscl . -search /Users UniqueID "$uid" | grep -q . || dscl . -search /Groups PrimaryGroupID "$uid" | grep -q .; do
    uid=$((uid + 1))
  done
  [ "$uid" -lt 500 ] || die "no free ID below 500"
  say "Creating the service account $ACCOUNT ($uid)"
  dscl . -create "/Groups/$ACCOUNT"
  dscl . -create "/Groups/$ACCOUNT" PrimaryGroupID "$uid"
  dscl . -create "/Groups/$ACCOUNT" RealName "agents-gateway"
  dscl . -create "/Groups/$ACCOUNT" Password '*'
  dscl . -create "/Users/$ACCOUNT"
  dscl . -create "/Users/$ACCOUNT" UniqueID "$uid"
  dscl . -create "/Users/$ACCOUNT" PrimaryGroupID "$uid"
  dscl . -create "/Users/$ACCOUNT" RealName "agents-gateway"
  dscl . -create "/Users/$ACCOUNT" NFSHomeDirectory /var/empty
  dscl . -create "/Users/$ACCOUNT" UserShell /usr/bin/false
  dscl . -create "/Users/$ACCOUNT" Password '*'
  dscl . -create "/Users/$ACCOUNT" IsHidden 1
fi

say "Installing to $PREFIX"
install -d -m 755 -o root -g wheel "$PREFIX" "$PREFIX/bin" "$PREFIX/libexec" /usr/local/var/lib /usr/local/var/run /usr/local/var/log
install -m 755 -o root -g wheel "$tmp/agents-gateway" "$PREFIX/bin/agents-gateway"
install -d -m 700 -o "$ACCOUNT" -g "$ACCOUNT" "$STATE"
install -d -m 755 -o "$ACCOUNT" -g "$ACCOUNT" "$RUN"
touch "$LOG" && chown "$ACCOUNT:$ACCOUNT" "$LOG" && chmod 644 "$LOG"

# git and gh run the gateway under those names (it dispatches on argv[0]),
# telling it the daemon's socket (unless set, as the end-to-end tests do)
# and the real programs.
for name in git gh; do
  cat >"$tmp/$name" <<WRAPPER
#!/bin/bash
export AGENTS_GATEWAY_SOCKET=\${AGENTS_GATEWAY_SOCKET:-$SOCKET}
export AGENTS_GATEWAY_REAL_GIT=$REAL_GIT
export AGENTS_GATEWAY_REAL_GH=$REAL_GH
exec -a $name $PREFIX/bin/agents-gateway "\$@"
WRAPPER
  install -m 755 -o root -g wheel "$tmp/$name" "$PREFIX/libexec/$name"
done

say "Putting the wrappers first on $AGENT_USER's PATH ($AGENT_HOME/.zshrc)"
zshrc=$AGENT_HOME/.zshrc
begin="# >>> $SERVICE >>>"
end="# <<< $SERVICE <<<"
touch "$zshrc"
# Last in the file, so nothing after it puts another git first.
sed -i '' "/^$begin\$/,/^$end\$/d" "$zshrc"
cat >>"$zshrc" <<BLOCK
$begin
# git and gh through agents-gateway (GitHub App tokens, per-agent attribution).
# Written by its macOS installer; restart raft-computer after changing.
export PATH="$PREFIX/libexec:\$PATH"
$end
BLOCK
chown "$AGENT_USER" "$zshrc"

say "launchd daemon $LABEL"
cat >"$tmp/plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>UserName</key><string>$ACCOUNT</string>
  <key>GroupName</key><string>$ACCOUNT</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PREFIX/bin/agents-gateway</string>
    <string>serve</string>
    <string>--socket</string><string>$SOCKET</string>
    <string>--app-id</string><string>$APP_ID</string>
    <string>--installation</string><string>$INSTALLATION</string>
    <string>--private-key-file</string><string>$KEY</string>
    <string>--commit-email</string><string>$COMMIT_EMAIL</string>
    <string>--allow-user</string><string>$AGENT_USER</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>Umask</key><integer>63</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
plutil -lint "$tmp/plist" >/dev/null
install -m 644 -o root -g wheel "$tmp/plist" "$PLIST"

launchctl bootout "system/$LABEL" 2>/dev/null || true
if [ ! -s "$KEY" ]; then
  cat <<NEXT

Installed agents-gateway $version, not started: the private key is missing.
Generate a new private key in the settings of the GitHub App nb-agents-gateway
(one per host), then:

  sudo install -m 600 -o $ACCOUNT -g $ACCOUNT ~/Downloads/<the downloaded>.pem $KEY
  sudo launchctl bootstrap system $PLIST

NEXT
  exit 0
fi
launchctl bootstrap system "$PLIST"
sleep 2
if launchctl print "system/$LABEL" | grep -q 'state = running'; then
  say "Running agents-gateway $version. Log: $LOG"
else
  tail -n 20 "$LOG" >&2 || true
  die "the daemon is not running; see $LOG"
fi
cat <<NEXT

As $AGENT_USER, open a new terminal (so the new PATH applies) and restart
raft-computer; then \`command -v git\` shows $PREFIX/libexec/git.
NEXT
