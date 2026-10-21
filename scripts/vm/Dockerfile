# Real x86_64 Linux kernel for testing, run with full-system emulation (qemu-system-x86_64) on an
# arm64 host. Docker's amd64 containers on Apple Silicon go through a user-mode translator
# (Rosetta or qemu-user) that loads ELF files itself, so they can't vouch for tricks that depend
# on the kernel's ELF loader. Used by scripts/vm-amd64.sh.
FROM --platform=linux/amd64 debian:trixie-slim AS amd64
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev musl-tools linux-image-amd64 busybox-static \
 && rm -rf /var/lib/apt/lists/*
COPY server.c /
RUN musl-gcc -static -Os -o /tcpserver /server.c && cp /boot/vmlinuz-* /kernel
# glibc, for the dynamically linked default builds
RUN mkdir -p /rootfs/lib64 /rootfs/lib/x86_64-linux-gnu \
 && cp -L /lib64/ld-linux-x86-64.so.2 /rootfs/lib64/ \
 && for l in libc.so.6 libm.so.6 libgcc_s.so.1 libpthread.so.0 libdl.so.2 librt.so.1 libresolv.so.2 libatomic.so.1; do \
      cp -L /lib/x86_64-linux-gnu/$l /rootfs/lib/x86_64-linux-gnu/ || true; done

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends qemu-system-x86 cpio \
 && rm -rf /var/lib/apt/lists/*
COPY --from=amd64 /kernel /tcpserver /bin/busybox /vm/
COPY --from=amd64 /rootfs /vm/rootfs
COPY init /vm/
