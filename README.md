# tiny-binaries

How small can a binary get? A hello world and a small TCP client, written in C, Go, Rust and V,
built for macOS arm64 and Linux arm64/amd64, from the plain release build down to the smallest
file that still passes the tests.

The rules are in [SPEC.md](SPEC.md). Every size below is a binary that passed `scripts/check.py`
on its platform.

## Results

<!-- results:start -->
### Smallest passing binary per language (bytes)

**hello**

| Language | darwin-arm64 | linux-arm64 | linux-amd64 |
|---|---:|---:|---:|
| C | 16,384 (`extreme`) | 142 (`extreme`) | 133 (`extreme`) |
| Go | 16,384 (`extreme`) | 170 (`extreme`) | 158 (`extreme`) |
| Rust | 16,384 (`extreme`) | 174 (`extreme`) | 165 (`extreme`) |
| V | 16,384 (`extreme`) | 140 (`extreme`) | 126 (`extreme`) |
| Assembly | 16,384 (`extreme`) | 166 (`optimized`) | 167 (`optimized`) |

**tcp**

| Language | darwin-arm64 | linux-arm64 | linux-amd64 |
|---|---:|---:|---:|
| C | 16,384 (`extreme`) | 442 (`extreme`) | 395 (`extreme`) |
| Go | 16,384 (`extreme`) | 300,056 (`tinygo`) | 264,784 (`tinygo`) |
| Rust | 16,384 (`extreme`) | 626 (`extreme`) | 589 (`extreme`) |
| V | 16,384 (`extreme`) | 332 (`extreme`) | 270 (`extreme`) |
| Assembly | 16,384 (`extreme`) | 454 (`optimized`) | 432 (`optimized`) |

### All variants (bytes)

**hello**

| Language | Variant | darwin-arm64 | linux-arm64 | linux-amd64 |
|---|---|---:|---:|---:|
| C | `default` | 33,440 | 70,432 | 15,952 |
| C | `extreme` | 16,384 | 142 | 133 |
| C | `extreme-strict` | 16,516 | - | - |
| C | `optimized` | 33,232 | 2,144 | 1,792 |
| C | `static` | - | 6,948 | 5,228 |
| Go | `default` | 2,429,714 | 2,341,917 | 2,342,609 |
| Go | `extreme` | 16,384 | 170 | 158 |
| Go | `extreme-ffi` | 16,782 | - | - |
| Go | `optimized` | 1,571,202 | 1,343,612 | 1,458,300 |
| Go | `tinygo` | 117,248 | 189,776 | 162,632 |
| Go | `upx` | - | 401,712 | 466,244 |
| Rust | `default` | 434,976 | 468,872 | 444,768 |
| Rust | `extreme` | 16,384 | 174 | 165 |
| Rust | `extreme-ffi` | 16,396 | - | - |
| Rust | `optimized` | 35,280 | 10,868 | 10,080 |
| V | `default` | 129,616 | 152,304 | 138,456 |
| V | `extreme` | 16,384 | 140 | 126 |
| V | `extreme-ffi` | 16,395 | - | - |
| V | `extreme-fullhash` | 16,505 | - | - |
| V | `optimized` | 33,049 | 3,568 | 2,912 |
| Assembly | `default` | 16,864 | 936 | 4,704 |
| Assembly | `extreme` | 16,384 | - | - |
| Assembly | `optimized` | 16,672 | 166 | 167 |

**tcp**

| Language | Variant | darwin-arm64 | linux-arm64 | linux-amd64 |
|---|---|---:|---:|---:|
| C | `default` | 34,088 | 70,952 | 16,512 |
| C | `extreme` | 16,384 | 442 | 395 |
| C | `extreme-strict` | 16,516 | - | - |
| C | `optimized` | 33,776 | 3,400 | 2,968 |
| C | `static` | - | 36,148 | 23,948 |
| Go | `default` | 3,343,538 | 3,332,010 | 3,455,309 |
| Go | `extreme` | 16,384 | fail | fail |
| Go | `extreme-ffi` | 17,020 | - | - |
| Go | `optimized` | 2,205,266 | 1,982,588 | 2,142,332 |
| Go | `tinygo` | - | 300,056 | 264,784 |
| Go | `upx` | - | 561,924 | 648,660 |
| Rust | `default` | 456,320 | 473,600 | 459,312 |
| Rust | `extreme` | 16,384 | 626 | 589 |
| Rust | `extreme-ffi` | 16,399 | - | - |
| Rust | `optimized` | 35,760 | 19,320 | 17,816 |
| V | `default` | 236,280 | 307,272 | 272,872 |
| V | `extreme` | 16,384 | 332 | 270 |
| V | `extreme-ffi` | 16,425 | - | - |
| V | `extreme-fullhash` | 16,505 | - | - |
| V | `optimized` | 66,281 | 71,992 | 70,976 |
| Assembly | `default` | 16,984 | 1,440 | 5,184 |
| Assembly | `extreme` | 16,384 | - | - |
| Assembly | `optimized` | 16,672 | 454 | 432 |

### Variants
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
