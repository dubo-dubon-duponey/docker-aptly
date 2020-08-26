#!/usr/bin/env bash
set -o errexit -o errtrace -o functrace -o nounset -o pipefail

# Ensure the data folder is writable
[ -w "/data" ] || {
  printf >&2 "/data is not writable. Check your mount permissions.\n"
  exit 1
}

# System constants
readonly PORT="${PORT:-}"
readonly ARCHITECTURES="${ARCHITECTURES:-}"

readonly CONFIG_LOCATION="${CONFIG_LOCATION:-/config/aptly.conf}"
readonly GPG_HOME="/data/gpg"
readonly KEYRING_LOCATION="${KEYRING_LOCATION:-$GPG_HOME/trustedkeys.gpg}"

readonly SUITE=buster
readonly DATE="$(date +%Y-%m-%d)"
readonly LONG_DATE="$(date +%Y%m%dT000000Z)"

readonly GPG_ARGS=(--no-default-keyring --homedir "$GPG_HOME/home" --keyring "$KEYRING_LOCATION")

mkdir -p "$GPG_HOME"

gpg::trust(){
  local server="$1"
  shift
  gpg "${GPG_ARGS[@]}" --keyserver "$server" --recv-keys "$@"
}

gpg::initialize(){
  local name="$1"
  local mail="$2"
  shift
  shift
  {
  cat <<EOF
     %echo Generating a gpg signing key
     %no-protection
     Key-Type: default
     Subkey-Type: default
     Name-Real: $name
     Name-Comment: Snapshot signing key
     Name-Email: $mail
     Expire-Date: 0
     $@
     %commit
     %echo done
EOF
  } | gpg "${GPG_ARGS[@]}" --batch --generate-key /dev/stdin >/dev/null 2>&1
  gpg "${GPG_ARGS[@]}" --output "$GPG_HOME"/snapshot-signing-public-key.pgp --armor --export "$mail"
  gpg --no-default-keyring --homedir "$GPG_HOME/home" --keyring "$GPG_HOME"/trusted.gpg --import "$GPG_HOME"/snapshot-signing-public-key.pgp
  >&2 printf "You need to gpg import %s to consume this repo - alternatively, copy over %s as /etc/apt/trusted.gpg\n" "$GPG_HOME/snapshot-signing-public-key.pgp" "$GPG_HOME/trusted.gpg"
}

com="${1:-}"
shift || true
case "$com" in
"aptly")
  # Typically create a new mirror with:
  # aptly mirror create "$nickname" "$url" "$suite" "$component"
  aptly -config="$CONFIG_LOCATION" -architectures="$ARCHITECTURES" "$@"
  exit
  ;;
"trust")
  # Typically "key server" "keys...": keys.gnupg.net 04EE7237B7D453EC 648ACFD622F3D138 EF0F382A1A7B6500 DCC9EFBF77E11517 AA8E81B4331F7F50 112695A0E562B32A
  gpg::trust "$@"
  exit
  ;;
"init")
  # Typically "My name" "My email"
  gpg::initialize "$@"
  exit
  ;;
"refresh")
  mirros="$(aptly -config="$CONFIG_LOCATION" -architectures="$ARCHITECTURES" mirror list -raw)"
  for mir in $mirros; do
    aptly -keyring="$KEYRING_LOCATION" -config="$CONFIG_LOCATION" -architectures="$ARCHITECTURES" mirror update "$mir" > /dev/null

    ! aptly -config="$CONFIG_LOCATION" -architectures="$ARCHITECTURES" publish show "$mir" :"archive/$mir/$LONG_DATE" > /dev/null || \
      aptly -config="$CONFIG_LOCATION" -architectures="$ARCHITECTURES" publish drop "$mir" :"archive/$mir/$LONG_DATE" > /dev/null

    ! aptly -config="$CONFIG_LOCATION" -architectures="$ARCHITECTURES" snapshot show "$mir-$DATE" > /dev/null || \
      aptly -config="$CONFIG_LOCATION" -architectures="$ARCHITECTURES" snapshot drop "$mir-$DATE" > /dev/null

    aptly -config="$CONFIG_LOCATION" -architectures="$ARCHITECTURES" snapshot create "$mir-$DATE" from mirror "$mir" > /dev/null
    aptly -keyring="$KEYRING_LOCATION" -config="$CONFIG_LOCATION" -architectures="$ARCHITECTURES" publish snapshot "$mir-$DATE" :"archive/$mir/$LONG_DATE" > /dev/null
  done
  ;;
esac

aptly::refresh(){
  local mirros
  local mir
  mirros="$(aptly -config="$CONFIG_LOCATION" -architectures="$ARCHITECTURES" mirror list -raw)"
  while true; do
    for mir in $mirros; do
      >&2 printf "Updating existing mirror %s\n" "$mir"
      aptly -keyring="$KEYRING_LOCATION" -config="$CONFIG_LOCATION" -architectures="$ARCHITECTURES" mirror update "$mir"

      # If we have a published snapshot at that date already, just continue
      >&2 printf "Have a published one already? If yes, continue.\n"
      ! aptly -config="$CONFIG_LOCATION" -architectures="$ARCHITECTURES" publish show "$mir" :"archive/$mir/$LONG_DATE" > /dev/null || continue

      # If we don't have a snapshot, create one
      if ! aptly -config="$CONFIG_LOCATION" -architectures="$ARCHITECTURES" snapshot show "$mir-$DATE" > /dev/null; then
        >&2 printf "No snapshot yet for that date and mirror, create one.\n"
        aptly -config="$CONFIG_LOCATION" -architectures="$ARCHITECTURES" snapshot create "$mir-$DATE" from mirror "$mir" > /dev/null
      fi

      # And publish
      >&2 printf "And... publish it\n"
      aptly -keyring="$KEYRING_LOCATION" -config="$CONFIG_LOCATION" -architectures="$ARCHITECTURES" publish snapshot "$mir-$DATE" :"archive/$mir/$LONG_DATE" > /dev/null
    done
    >&2 printf "Going to sleep for a day now\n"
    sleep 86400
  done
}

dnssd::advertize() {
  local name="$1"
  local type="$2"
  local port="$3"
  shift
  shift
  shift

  while true; do
    dns-sd -R "$name" "$type" . "$port" "$@" || {
      >&2 printf "dns-sd just failed! Going to sleep a bit and try again"
      sleep 10
    }
  done
}

#aptly::refresh &
#dnssd::advertize "apt" "_apt._tcp" "$PORT" &

args=(caddy -conf /config/caddy/main.conf -agree -http-port "$PORT")

exec "${args[@]}" "$@"

#############################
# Key generation part
#############################
# gpg --no-default-keyring --keyring /data/aptly/gpg/trustedkeys.gpg --gen-key
# gpg --no-default-keyring --keyring /data/aptly/gpg/trustedkeys.gpg --output public.pgp --armor --export dubo-dubon-duponey@farcloser.world
# gpg --output private.pgp --armor --export-secret-key dubo-dubon-duponey@farcloser.world
# gpg --no-default-keyring --keyring /data/aptly/gpg/trustedkeys.gpg --import private.pgp

#############################
# Initialization
#############################
# gpg --no-default-keyring --keyring /data/aptly/gpg/trustedkeys.gpg --keyserver pool.sks-keyservers.net --recv-keys 04EE7237B7D453EC 648ACFD622F3D138 EF0F382A1A7B6500 DCC9EFBF77E11517 AA8E81B4331F7F50 112695A0E562B32A
# aptly -keyring=/data/aptly/gpg/trustedkeys.gpg -config /config/aptly.conf -architectures=amd64,arm64,armel,armhf mirror create buster http://deb.debian.org/debian buster main
# aptly -keyring=/data/aptly/gpg/trustedkeys.gpg -config /config/aptly.conf -architectures=amd64,arm64,armel,armhf mirror create buster-updates http://deb.debian.org/debian buster-updates main
# aptly -keyring=/data/aptly/gpg/trustedkeys.gpg -config /config/aptly.conf -architectures=amd64,arm64,armel,armhf mirror create buster-security http://security.debian.org/debian-security buster/updates main

#############################
# Recurring at DATE=YYYY-MM-DD
#############################
# SUITE=buster
# DATE="$(date +%Y-%m-%d)"
# LONG_DATE="$(date +%Y%m%dT000000Z)"

# Update the mirrors
# aptly -keyring=/data/aptly/gpg/trustedkeys.gpg -config /config/aptly.conf mirror update $SUITE
# aptly -keyring=/data/aptly/gpg/trustedkeys.gpg -config /config/aptly.conf mirror update $SUITE-updates
# aptly -keyring=/data/aptly/gpg/trustedkeys.gpg -config /config/aptly.conf mirror update $SUITE-security

# Create snapshots
# aptly -config /config/aptly.conf snapshot create $SUITE-$DATE from mirror $SUITE
# aptly -config /config/aptly.conf snapshot create $SUITE-updates-$DATE from mirror $SUITE-updates
# aptly -config /config/aptly.conf snapshot create $SUITE-security-$DATE from mirror $SUITE-security

# Publish snaps
# gpg --no-default-keyring --keyring /data/aptly/gpg/trustedkeys.gpg --import /data/aptly/gpg/private.pgp
# Just force gpg to preconfig
# gpg --no-default-keyring --keyring /data/aptly/gpg/trustedkeys.gpg --list-keys

# aptly -keyring=/data/aptly/gpg/trustedkeys.gpg -config /config/aptly.conf publish snapshot $SUITE-$DATE :archive/debian/$LONG_DATE
# aptly -keyring=/data/aptly/gpg/trustedkeys.gpg -config /config/aptly.conf publish snapshot $SUITE-updates-$DATE :archive/debian/$LONG_DATE
# aptly -keyring=/data/aptly/gpg/trustedkeys.gpg -config /config/aptly.conf publish snapshot $SUITE-security-$DATE :archive/debian-security/$LONG_DATE

# XXX aptly serve - use straight caddy from files instead
# move to https meanwhile
# add authentication
# deliver the public key as part of the filesystem
# On the receiving end
# echo "$GPG_PUB" | apt-key add
# apt-get -o Dir::Etc::SourceList=/dev/stdin update

# XXX to remove: aptly -config /config/aptly.conf publish drop buster-updates :archive/debian/$LONG_DATE