ARG           BUILDER_BASE=dubodubonduponey/base@sha256:b51f084380bc1bd2b665840317b6f19ccc844ee2fc7e700bf8633d95deba2819
ARG           RUNTIME_BASE=dubodubonduponey/base@sha256:d28e8eed3e87e8dc5afdd56367d3cf2da12a0003d064b5c62405afbe4725ee99

#######################
# Extra builder for healthchecker
#######################
# hadolint ignore=DL3006
FROM          --platform=$BUILDPLATFORM $BUILDER_BASE                                                                   AS builder-healthcheck

ARG           GIT_REPO=github.com/dubo-dubon-duponey/healthcheckers
ARG           GIT_VERSION=51ebf8ca3d255e0c846307bf72740f731e6210c3

WORKDIR       $GOPATH/src/$GIT_REPO
RUN           git clone git://$GIT_REPO .
RUN           git checkout $GIT_VERSION
RUN           arch="${TARGETPLATFORM#*/}"; \
              env GOOS=linux GOARCH="${arch%/*}" go build -v -ldflags "-s -w" \
                -o /dist/boot/bin/http-health ./cmd/http

#######################
# Builder custom
#######################
# XXX mirror is shit - it fails at the first network error, and does not "resume" the state
# hadolint ignore=DL3006
FROM          --platform=$BUILDPLATFORM $BUILDER_BASE                                                                   AS builder-mirror

ARG           GIT_REPO=github.com/cybozu-go/aptutil
ARG           GIT_VERSION=3f82d83844818cdd6a6d7dca3eca0f76d8a3fce5
ARG           GO_LDFLAGS=""

WORKDIR       $GOPATH/src/$GIT_REPO
RUN           git clone git://$GIT_REPO .
RUN           git checkout $GIT_VERSION
RUN           arch="${TARGETPLATFORM#*/}"; \
              env GOOS=linux GOARCH="${arch%/*}" go build -v -ldflags "-s -w $GO_LDFLAGS" -o /dist/boot/bin/apt-mirror ./cmd/go-apt-mirror/main.go

COPY          --from=builder-healthcheck /dist/boot/bin /dist/boot/bin
RUN           chmod 555 /dist/boot/bin/*

#######################
# Builder custom (cacher)
#######################
# hadolint ignore=DL3006
FROM          --platform=$BUILDPLATFORM $BUILDER_BASE                                                                   AS builder-cacher

ARG           GIT_REPO=github.com/cybozu-go/aptutil
ARG           GIT_VERSION=3f82d83844818cdd6a6d7dca3eca0f76d8a3fce5
ARG           GO_LDFLAGS=""

WORKDIR       $GOPATH/src/$GIT_REPO
RUN           git clone git://$GIT_REPO .
RUN           git checkout $GIT_VERSION
RUN           arch="${TARGETPLATFORM#*/}"; \
              env GOOS=linux GOARCH="${arch%/*}" go build -v -ldflags "-s -w $GO_LDFLAGS" -o /dist/boot/bin/apt-cacher ./cmd/go-apt-cacher/main.go

COPY          --from=builder-healthcheck /dist/boot/bin /dist/boot/bin
RUN           chmod 555 /dist/boot/bin/*


#######################
# Aptly
#######################
# hadolint ignore=DL3006
FROM          --platform=$BUILDPLATFORM $BUILDER_BASE                                                                   AS builder-aptly

ARG           GIT_REPO=github.com/aptly-dev/aptly
ARG           GIT_VERSION=24a027194ea8818307083396edb76565f41acc92
ARG           GO_LDFLAGS="-s -w"

WORKDIR       $GOPATH/src/$GIT_REPO
RUN           git clone git://$GIT_REPO .
RUN           git checkout $GIT_VERSION
RUN           arch="${TARGETPLATFORM#*/}"; \
              env GOOS=linux GOARCH="${arch%/*}" go build -v -ldflags "$GO_LDFLAGS -X main.Version=$BUILD_VERSION" \
                -o /dist/boot/bin/aptly ./main.go

#######################
# Caddy
#######################
# hadolint ignore=DL3006
FROM          --platform=$BUILDPLATFORM $BUILDER_BASE                                                                   AS builder-caddy

# This is 1.0.5
ARG           GIT_REPO=github.com/caddyserver/caddy
ARG           GIT_VERSION=11ae1aa6b88e45b077dd97cb816fe06cd91cca67
ARG           GO_LDFLAGS="-s -w"

WORKDIR       $GOPATH/src/$GIT_REPO
RUN           git clone https://$GIT_REPO .
RUN           git checkout $GIT_VERSION

COPY          builder/main.go cmd/caddy/main.go

RUN           arch="${TARGETPLATFORM#*/}"; \
              GOOS=linux GOARCH="${arch%/*}" go build -v -ldflags "$GO_LDFLAGS" \
                -o /dist/boot/bin/caddy ./cmd/caddy

#######################
# Builder assembly
#######################
FROM          $BUILDER_BASE                                                                                             AS builder

COPY          --from=builder-healthcheck /dist/boot/bin /dist/boot/bin
COPY          --from=builder-aptly /dist/boot/bin /dist/boot/bin
COPY          --from=builder-caddy /dist/boot/bin /dist/boot/bin
COPY          --from=builder-cacher /dist/boot/bin /dist/boot/bin

RUN           chmod 555 /dist/boot/bin/*; \
              epoch="$(date --date "$BUILD_CREATED" +%s)"; \
              find /dist/boot/bin -newermt "@$epoch" -exec touch --no-dereference --date="@$epoch" '{}' +;

#######################
# Running image
#######################
# hadolint ignore=DL3006
FROM          $RUNTIME_BASE                                                                                             AS runtime

USER          root

RUN           apt-get update -qq          && \
              apt-get install -qq --no-install-recommends \
                bzip2=1.0.6-9.2~deb10u1 \
                xz-utils=5.2.4-1 \
                nano \
                gnupg=2.2.12-1+deb10u1 && \
              apt-get -qq autoremove      && \
              apt-get -qq clean           && \
              rm -rf /var/lib/apt/lists/* && \
              rm -rf /tmp/*               && \
              rm -rf /var/tmp/*

USER          dubo-dubon-duponey

COPY          --from=builder --chown=$BUILD_UID:root /dist .

EXPOSE        8080/tcp

VOLUME        /data

ENV           USERNAME=dubo-dubon-duponey
ENV           PASSWORD=l00t
ENV           ARCHITECTURES=amd64,arm64,armel,armhf

# System constants, unlikely to ever require modifications in normal use
ENV           HEALTHCHECK_URL=http://127.0.0.1:10042/healthcheck
ENV           PORT=8080

HEALTHCHECK   --interval=30s --timeout=30s --start-period=10s --retries=1 CMD http-health || exit 1

# With the final script:
# CONFIG_LOCATION=/config/aptly.conf KEYRING_LOCATION=/data/aptly/gpg/trustedkeys.gpg ARCHITECTURES=amd64 ./test.sh trust keys.gnupg.net 04EE7237B7D453EC 648ACFD622F3D138 EF0F382A1A7B6500 DCC9EFBF77E11517 AA8E81B4331F7F50 112695A0E562B32A
# CONFIG_LOCATION=/config/aptly.conf KEYRING_LOCATION=/data/aptly/gpg/trustedkeys.gpg ARCHITECTURES=amd64 ./test.sh aptly mirror create buster-updates http://deb.debian.org/debian buster-updates main


# With aptly
# gpg --no-default-keyring --keyring trustedkeys.gpg --keyserver keys.gnupg.net --recv-keys AA8E81B4331F7F50 112695A0E562B32A
# aptly -gpg-provider=internal -architectures=amd64,arm64,armel,armhf mirror create debian-security http:// buster/updates main
# aptly mirror update debian-security
# aptly snapshot create debian-security-2020-08-10 from mirror debian-security
# aptly publish snapshot debian-security-2020-08-10 buster/updates:archive/debian-security/20200801T000000Z

# aptly publish snapshot debian-security-2020-08-10 :archive/debian-security/20200810T000000Z


# deb http://snapshot.debian.org/archive/debian/20200607T000000Z buster main
#deb http://deb.debian.org/debian buster main
# deb http://snapshot.debian.org/archive/debian-security/20200607T000000Z buster/updates main
#deb http://security.debian.org/debian-security buster/updates main
# deb http://snapshot.debian.org/archive/debian/20200607T000000Z buster-updates main
#deb http://deb.debian.org/debian buster-updates main

# All in
# gpg --no-default-keyring --keyring trustedkeys.gpg --keyserver keys.gnupg.net --recv-keys EF0F382A1A7B6500 DCC9EFBF77E11517
# aptly -architectures=amd64,arm64,armel,armhf mirror create buster http://deb.debian.org/debian buster main

# gpg --no-default-keyring --keyring trustedkeys.gpg --keyserver keys.gnupg.net --recv-keys 04EE7237B7D453EC 648ACFD622F3D138
# aptly -architectures=amd64,arm64,armel,armhf mirror create buster-updates http://deb.debian.org/debian buster-updates main

# gpg --no-default-keyring --keyring trustedkeys.gpg --keyserver keys.gnupg.net --recv-keys AA8E81B4331F7F50 112695A0E562B32A
# aptly -architectures=amd64,arm64,armel,armhf mirror create buster-security http://security.debian.org/debian-security buster/updates main

# aptly mirror update buster
# aptly mirror update buster-updates
# aptly mirror update buster-security

# aptly snapshot create buster-2020-08-10 from mirror buster
# aptly snapshot create buster-updates-2020-08-10 from mirror buster-updates
# aptly snapshot create buster-security-2020-08-10 from mirror buster-security

# gpg --gen-key
# aptly -skip-signing publish snapshot buster-updates-2020-08-10 :archive/debian/20200810T000000Z

# aptly serve


# gpg --output public.pgp --armor --export foo@bar.com
# apt-key add yak.pgp


#############################
# Key generation part
#############################
# gpg --gen-key
# gpg --output public.pgp --armor --export dubo-dubon-duponey@farcloser.world
# gpg --output private.pgp --armor --export-secret-key dubo-dubon-duponey@farcloser.world

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
# gpg --no-default-keyring --keyring /data/aptly/gpg/trustedkeys.gpg --list-keys>

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