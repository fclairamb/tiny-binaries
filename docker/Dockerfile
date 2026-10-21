# Linux toolchain image. Built once per architecture:
#   docker build --platform linux/arm64 -t tiny-binaries:arm64 docker
#   docker build --platform linux/amd64 -t tiny-binaries:amd64 docker
FROM debian:trixie-slim

ARG GO_VERSION=1.27.0
ARG TINYGO_VERSION=0.43.0
ARG V_VERSION=0.5.2
ARG RUST_NIGHTLY=nightly-2026-10-20

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential clang lld llvm musl-tools musl-dev binutils make git curl ca-certificates \
      python3 xz-utils unzip upx-ucl elfkickers file bsdextrautils strace \
 && rm -rf /var/lib/apt/lists/* \
 && { command -v upx >/dev/null || ln -s /usr/bin/upx-ucl /usr/local/bin/upx; }

RUN arch=$(dpkg --print-architecture) \
 && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" | tar -xz -C /usr/local \
 && curl -fsSL "https://github.com/tinygo-org/tinygo/releases/download/v${TINYGO_VERSION}/tinygo${TINYGO_VERSION}.linux-${arch}.tar.gz" | tar -xz -C /usr/local

ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable \
 && /usr/local/cargo/bin/rustup toolchain install "${RUST_NIGHTLY}" --profile minimal --component rust-src \
 && t="$(uname -m)-unknown-linux-musl" \
 && /usr/local/cargo/bin/rustup target add "$t" --toolchain stable \
 && /usr/local/cargo/bin/rustup target add "$t" --toolchain "${RUST_NIGHTLY}" \
 && chmod -R a+rwX /usr/local/rustup /usr/local/cargo

# The release zips: building from the tag fetches the latest vc (bootstrap C), which no longer
# compiles the tagged sources.
RUN z=v_linux.zip && { [ "$(dpkg --print-architecture)" != arm64 ] || z=v_linux_arm64.zip; } \
 && curl -fsSL -o /tmp/v.zip "https://github.com/vlang/v/releases/download/${V_VERSION}/$z" \
 && unzip -q /tmp/v.zip -d /opt && rm /tmp/v.zip \
 && chmod -R a+rwX /opt/v && /opt/v/v version

ENV PATH=/usr/local/go/bin:/usr/local/tinygo/bin:/usr/local/cargo/bin:/opt/v:$PATH \
    GOCACHE=/tmp/gocache GOPATH=/tmp/gopath \
    VCACHE=/tmp/vcache VMODULES=/tmp/vmodules
WORKDIR /src
