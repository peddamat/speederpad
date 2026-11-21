FROM debian:bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        mmdebstrap qemu-user-static binfmt-support debian-archive-keyring arch-test \
        e2fsprogs xz-utils python3 git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
ENTRYPOINT ["./build.sh"]
