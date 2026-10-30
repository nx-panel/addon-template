#!/bin/sh
# Installs, updates or removes this NX addon on a Linux host — by hand, or
# by the panel over SSH (the same way it installs a node). Run it as root.
#
#   sh install.sh --method docker --opt port=8090 --panel-url https://panel.example --claim-code ABC123
#   sh install.sh --method script --version v0.1.0
#   sh install.sh --uninstall [--purge]
#
# --method script   the binary under a systemd unit (no Docker needed)
# --method docker   the compose stack in deploy/compose.yml
# --version TAG     a release tag (default: the latest release)
# --binary-file F   install this archive instead of downloading one (script)
# --sha256 HEX      the archive's SHA-256, checked before it is installed: the
#                   panel hands it from the release's signed SHA256SUMS
# --opt KEY=VALUE   an answer to one of the manifest's install options; repeat
# --panel-url URL   the panel's address, passed as NX_PANEL_URL
# --claim-code C    the one-time code the panel registers the addon with
# --uninstall       stop and remove the addon; --purge also deletes its data
#
# Running it again updates in place: the answers already given are kept
# unless --opt changes them, and the data directory is never touched.
set -eu

SLUG="template"
REPO="nx-panel/addon-template"
BIN="addon-template"
DIR="/opt/nx-addons/${SLUG}"
UNIT="nx-addon-${SLUG}"

METHOD=""
VERSION=""
BINARY_FILE=""
SHA256=""
PANEL_URL=""
CLAIM_CODE=""
UNINSTALL=0
PURGE=0
OPTS=""

die() { echo "install: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
	--method) METHOD="$2"; shift 2 ;;
	--version) VERSION="$2"; shift 2 ;;
	--binary-file) BINARY_FILE="$2"; shift 2 ;;
	--sha256) SHA256="$2"; shift 2 ;;
	--opt)
		case "$2" in *=*) ;; *) die "--opt takes KEY=VALUE" ;; esac
		OPTS="${OPTS}$2
"
		shift 2 ;;
	--panel-url) PANEL_URL="$2"; shift 2 ;;
	--claim-code) CLAIM_CODE="$2"; shift 2 ;;
	--uninstall) UNINSTALL=1; shift ;;
	--purge) PURGE=1; shift ;;
	*) die "unknown argument $1" ;;
	esac
done

[ "$(id -u)" = 0 ] || die "run as root"

# An install made under the product's old name is moved first: its unit or
# its containers are stopped, its directory moves to ${DIR} with its answers
# and data, and the answers take their new names. The run then goes on as an
# update, and the panel's claim code registers it again. Each step looks
# before it acts, so a run cut off halfway is finished by the next one.
OLD_DIR="/opt/nexora-addons/${SLUG}" # rebrand-ok
OLD_UNIT="nexora-addon-${SLUG}"      # rebrand-ok
OLD_BIN="${BIN}"
# A snapshot of the old install is taken first, and a run that stops early
# after the move — a die, or a command that failed under set -e — puts it back
# and starts it again; the next run tries the move again. A run cut off before
# it finished leaves its record (MARK), and the next one takes that snapshot,
# which holds the install from before any of it was moved.
MARK="$(dirname "$DIR")/.${SLUG}.transfer"
SNAP=""
MOVED=0
DIR_BEFORE=0
restore_move() {
	[ "$MOVED" = 1 ] || return 0
	MOVED=0
	echo "install: putting ${SLUG} from before the move back" >&2
	if [ -f "/etc/systemd/system/${UNIT}.service" ]; then
		systemctl disable --now "$UNIT" 2>/dev/null || true
		rm -f "/etc/systemd/system/${UNIT}.service"
	fi
	if [ -f "${DIR}/compose.yml" ] && command -v docker >/dev/null 2>&1; then
		docker compose -f "${DIR}/compose.yml" --env-file "${DIR}/.env" down 2>/dev/null || true
	fi
	[ -n "$SNAP" ] || return 0
	# An install already here before the move is left as it is.
	[ "$DIR_BEFORE" = 1 ] || rm -rf "${DIR:?}"
	tar -C / -xzf "$SNAP" || { echo "install: could not unpack ${SNAP}" >&2; return 0; }
	rm -f "$MARK"
	systemctl daemon-reload 2>/dev/null || true
	if [ -f "/etc/systemd/system/${OLD_UNIT}.service" ]; then
		systemctl enable --now "$OLD_UNIT" >/dev/null 2>&1 || true
	elif [ -f "${OLD_DIR}/compose.yml" ] && command -v docker >/dev/null 2>&1; then
		docker compose -f "${OLD_DIR}/compose.yml" --env-file "${OLD_DIR}/.env" up -d >/dev/null 2>&1 || true
	fi
	echo "install: ${SLUG} runs again under its old name" >&2
}
# One EXIT trap for the run: the files it leaves to clean up, then the restore.
CLEANUP=""
on_exit() {
	rc=$?
	# shellcheck disable=SC2086 # a list of paths without spaces
	[ -z "$CLEANUP" ] || rm -rf $CLEANUP
	[ "$rc" = 0 ] || restore_move
}
trap on_exit EXIT
if [ -f "$MARK" ] || [ -e "$OLD_DIR" ] || [ -f "/etc/systemd/system/${OLD_UNIT}.service" ]; then
	echo "moving ${SLUG} installed under the old name"
	if [ -f "/etc/systemd/system/${OLD_UNIT}.service" ]; then
		systemctl disable --now "$OLD_UNIT" 2>/dev/null || true
	fi
	if [ -f "${OLD_DIR}/compose.yml" ] && command -v docker >/dev/null 2>&1; then
		docker compose -f "${OLD_DIR}/compose.yml" --env-file "${OLD_DIR}/.env" down || true
	fi
	mkdir -p "$(dirname "$DIR")"
	if [ -f "$MARK" ]; then
		SNAP="$(sed -n 1p "$MARK")"
		DIR_BEFORE="$(sed -n 2p "$MARK")"
		[ -f "$SNAP" ] || SNAP=""
	elif [ -e "$DIR" ]; then
		DIR_BEFORE=1
	fi
	if [ -z "$SNAP" ] && [ -e "$OLD_DIR" ]; then
		# Taken with the old one stopped, and kept only whole: a cut-off
		# archive would truncate what it puts back.
		SNAP="$(dirname "$DIR")/.${SLUG}-transfer.tar.gz"
		set -- "${OLD_DIR#/}"
		[ ! -f "/etc/systemd/system/${OLD_UNIT}.service" ] || set -- "$@" "etc/systemd/system/${OLD_UNIT}.service"
		(umask 077 && tar -C / -czf "$SNAP" "$@") || { rm -f "$SNAP"; die "could not save the old install; nothing was moved"; }
	fi
	(umask 077 && printf '%s\n%s\n' "$SNAP" "$DIR_BEFORE" >"$MARK")
	MOVED=1
	if [ -e "$OLD_DIR" ]; then
		if [ -e "$DIR" ]; then
			cp -a "${OLD_DIR}/." "${DIR}/" && rm -rf "${OLD_DIR:?}"
		else
			mv "$OLD_DIR" "$DIR"
		fi
	fi
	if [ -f "${DIR}/.env" ]; then
		sed -i "s#^NEXORA_#NX_#; s#${OLD_DIR}#${DIR}#g" "${DIR}/.env" # rebrand-ok
	fi
	rm -f "/etc/systemd/system/${OLD_UNIT:?}.service" "${DIR:?}/bin/${OLD_BIN:?}" "${DIR:?}/compose.yml"
	systemctl daemon-reload 2>/dev/null || true
	rmdir "$(dirname "$OLD_DIR")" 2>/dev/null || true
fi

if [ "$UNINSTALL" = 1 ]; then
	if [ -f "/etc/systemd/system/${UNIT}.service" ]; then
		systemctl disable --now "$UNIT" 2>/dev/null || true
		rm -f "/etc/systemd/system/${UNIT}.service"
		systemctl daemon-reload
	fi
	if [ -f "${DIR}/compose.yml" ] && command -v docker >/dev/null 2>&1; then
		docker compose -f "${DIR}/compose.yml" --env-file "${DIR}/.env" down || true
	fi
	if [ "$PURGE" = 1 ]; then
		rm -rf "$DIR"
	else
		rm -rf "${DIR}/bin" "${DIR}/compose.yml"
	fi
	rm -f "$MARK" "$SNAP"
	echo "removed ${SLUG}"
	exit 0
fi

# An update keeps the method the addon was installed with.
if [ -z "$METHOD" ] && [ -f "${DIR}/.method" ]; then
	METHOD="$(cat "${DIR}/.method")"
fi
case "$METHOD" in
script | docker) ;;
*) die "--method script or --method docker" ;;
esac

if [ -z "$VERSION" ]; then
	VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
	[ -n "$VERSION" ] || die "could not read the latest release of ${REPO}"
fi

mkdir -p "${DIR}/data"
chmod 700 "${DIR}"
echo "$METHOD" >"${DIR}/.method"

# envquote VALUE: the value as both readers of the .env take it literally —
# systemd's EnvironmentFile and docker compose's env_file. Single quotes are
# literal to both; a value holding one goes in double quotes, with \ and "
# escaped, and for compose, which expands $ inside them, $ doubled.
envquote() {
	case "$1" in
	*\'*) ;;
	*)
		printf "'%s'" "$1"
		return
		;;
	esac
	v="$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
	[ "$METHOD" != docker ] || v="$(printf '%s' "$v" | sed 's/\$/$$/g')"
	printf '"%s"' "$v"
}

# setenv KEY VALUE: replace or add one line of the .env file.
setenv() {
	touch "${DIR}/.env"
	chmod 600 "${DIR}/.env"
	grep -v "^$1=" "${DIR}/.env" >"${DIR}/.env.tmp" || true
	printf '%s=%s\n' "$1" "$(envquote "$2")" >>"${DIR}/.env.tmp"
	mv "${DIR}/.env.tmp" "${DIR}/.env"
	chmod 600 "${DIR}/.env" # the mv carries the temporary file's mode, not the 600 above
}

printf '%s' "$OPTS" | while IFS= read -r kv; do
	[ -n "$kv" ] || continue
	key="$(printf '%s' "${kv%%=*}" | tr 'a-z' 'A-Z')"
	setenv "NX_OPT_${key}" "${kv#*=}"
done
[ -z "$PANEL_URL" ] || setenv NX_PANEL_URL "$PANEL_URL"
[ -z "$CLAIM_CODE" ] || setenv NX_CLAIM_CODE "$CLAIM_CODE"
setenv NX_ADDON_VERSION "${VERSION#v}"

case "$METHOD" in
script)
	case "$(uname -m)" in
	x86_64 | amd64) ARCH=amd64 ;;
	aarch64 | arm64) ARCH=arm64 ;;
	*) die "no build of ${SLUG} for $(uname -m)" ;;
	esac
	setenv NX_DATA_DIR "${DIR}/data"
	tmp="$(mktemp -d)"
	CLEANUP="${CLEANUP} ${tmp}"
	if [ -n "$BINARY_FILE" ]; then
		cp "$BINARY_FILE" "${tmp}/addon.tar.gz"
	else
		curl -fsSL -o "${tmp}/addon.tar.gz" \
			"https://github.com/${REPO}/releases/download/${VERSION}/${BIN}-linux-${ARCH}.tar.gz"
	fi
	if [ -n "$SHA256" ]; then
		if command -v sha256sum >/dev/null 2>&1; then
			got="$(sha256sum "${tmp}/addon.tar.gz" | cut -d' ' -f1)"
		else
			got="$(shasum -a 256 "${tmp}/addon.tar.gz" | cut -d' ' -f1)"
		fi
		[ "$got" = "$(printf '%s' "$SHA256" | tr 'A-F' 'a-f')" ] || die "the archive's SHA-256 is ${got}, not the ${SHA256} the release signed"
	fi
	tar -xzf "${tmp}/addon.tar.gz" -C "$tmp"
	mkdir -p "${DIR}/bin"
	install -m 755 "${tmp}/${BIN}" "${DIR}/bin/${BIN}"
	cat >"/etc/systemd/system/${UNIT}.service" <<UNIT
[Unit]
Description=NX addon ${SLUG}
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=${DIR}/.env
WorkingDirectory=${DIR}
ExecStart=${DIR}/bin/${BIN}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
	systemctl daemon-reload
	systemctl enable "$UNIT" >/dev/null 2>&1
	systemctl restart "$UNIT"
	;;
docker)
	command -v docker >/dev/null 2>&1 || die "docker is not installed; use --method script"
	chown 10001 "${DIR}/data" # the image runs as uid 10001
	curl -fsSL -o "${DIR}/compose.yml" "https://raw.githubusercontent.com/${REPO}/${VERSION}/deploy/compose.yml"
	docker compose -f "${DIR}/compose.yml" --env-file "${DIR}/.env" pull
	docker compose -f "${DIR}/compose.yml" --env-file "${DIR}/.env" up -d
	;;
esac

echo "installed ${SLUG} ${VERSION} (${METHOD}) in ${DIR}"
# The move is done once the new one runs: what only a restore needed goes.
if [ "$MOVED" = 1 ]; then
	MOVED=0
	rm -f "$MARK" "$SNAP"
fi
# The registration files the old kit kept beside the data; this kit writes
# nx-credentials.json and nx-claim, so they are left from the old name only.
rm -f "${DIR}/data/nexora-credentials.json" "${DIR}/data/nexora-claim" # rebrand-ok
