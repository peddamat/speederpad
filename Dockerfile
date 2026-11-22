FROM debian:bookworm

RUN apt-get update \
    && cross="$([ "$(dpkg --print-architecture)" = arm64 ] || echo gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu)" \
    && apt-get install -y --no-install-recommends \
        mmdebstrap qemu-user-static binfmt-support debian-archive-keyring arch-test \
        e2fsprogs xz-utils python3 git curl ca-certificates \
        build-essential bc flex bison $cross \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
ENTRYPOINT ["./build.sh"]
