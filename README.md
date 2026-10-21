# tiny-binaries

How small can a binary get? A hello world and a small TCP client, written in C, Go, Rust and V,
built for macOS arm64 and Linux arm64/amd64, from the plain release build down to the smallest
file that still passes the tests.

The rules are in [SPEC.md](SPEC.md). Every size below is a binary that passed `scripts/check.py`
on its platform.

## Results

<!-- results:start -->
<!-- results:end -->

## Running it

You need an Apple Silicon Mac with Docker (OrbStack works) for the Linux builds.

```bash
docker build --platform linux/arm64 -t tiny-binaries:arm64 docker
docker build --platform linux/amd64 -t tiny-binaries:amd64 docker
scripts/run.sh                      # build and test everything
scripts/run.sh -p linux-amd64 c     # one platform, one language
scripts/vm-amd64.sh out/linux-amd64/c   # same tests on a real x86_64 kernel (qemu)
scripts/report.py                   # refresh the tables above
```

The macOS builds need the toolchains on the host: Xcode command line tools, Go, Rust (with
rustup for nightly), [V](https://vlang.io) and [TinyGo](https://tinygo.org).
