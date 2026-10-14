<p align="center">
    <a href="https://ntsc.rs">
        <picture>
            <source media="(prefers-color-scheme: dark)" srcset="./docs/img/logo-darkmode.svg">
            <img alt="ntsc-rs logo" src="./docs/img/logo-lightmode.svg" width="1216">
        </picture>
    </a>
</p>

# NTSC-rs: Apple Silicon performance fork

I use NTSC-rs on 4K long-form videos in DaVinci Resolve. I forked it because rendering the effect was taking too long, and I wanted to use more of the CPU and GPU already in my Mac.

This is a public performance fork of [ntsc-rs/ntsc-rs](https://github.com/ntsc-rs/ntsc-rs). It keeps the original NTSC/VHS effect and focuses on its **OpenFX plugin for Resolve on Apple Silicon**. OpenFX, or OFX, is the video plugin format. The upstream project and its contributors created the effect; this fork adds CPU threading, an optional NEON filter implementation, and a Metal renderer.

## What changed

- **CPU threading:** the OpenFX crate now enables the core's existing Rayon thread pool. This was the largest measured improvement.
- **NEON filters:** independent scanlines run together in ARM vector lanes. The tested CPU output remains bit-identical to the existing SIMD path.
- **Metal rendering:** pixel processing runs on the host's Metal queue. Rust still generates filter coefficients and deterministic random decisions. Recursive filters use a serial GPU path where parallel grouping would introduce too much numerical error.
- **Current upstream features:** the fork incorporates upstream main at `450c6ee`, including the new 2D and adaptive 2D chroma filters. It preserves the `wtf.vala:NtscRs` plugin identifier so existing projects can load the replacement.

The fork's `main` branch enables Metal by default for the OpenFX crate. The upstream proposal leaves it opt-in. Metal code is restricted to Apple Silicon macOS; other platforms retain CPU rendering. A CPU-only plugin can be built with `cargo build -p ntsc-rs-openfx-plugin --no-default-features`.

## How much faster?

Measurements below used an M4 Max with 64 GB memory. They measure different parts of the pipeline and should not be multiplied together.

| Comparison | Before | After | Measured improvement |
| --- | ---: | ---: | ---: |
| Current-main 4K CPU harness: serial to Rayon | 100.887 ms/frame | 14.718 ms/frame | 6.85x |
| Current-main 4K CPU harness: Rayon to Rayon + NEON | 14.761 ms/frame | 14.017 ms/frame | About 5% |
| Current-main 4K rendering: optimized CPU to Metal host buffers | 12.968 ms/frame | 11.382 ms/frame | 1.14x |
| Earlier v0.9.6-based Resolve build: stock to optimized, 59-frame 4K export | 10.223 s | 1.773 s | 5.77x |

The Resolve result is the median of three paired H.264 exports in Resolve Studio 21.1. It includes the CPU-threading improvement; **it is not a 5.77x Metal-only speedup**. That host benchmark used the earlier v0.9.6-based build. The current-main results use in-memory frames without decoding or encoding. They are not sustained playback FPS or a promise about every preset, codec, or machine.

The current implementation passes 67 CPU tests and five explicit GPU tests. Twenty 4K configurations had a maximum absolute RGB difference of 0.000045002 from the CPU reference. Metal output is close, but not bit-identical. A 600-frame in-memory run also completed successfully. [Read the test method, CSV results, and limitations](docs/performance/metal-openfx.md).

## Build the optimized Resolve plugin

Requires Apple Silicon, macOS 11 or newer, a current Rust toolchain, and Xcode command-line tools. The build script packages the OpenFX plugin; it does not install a standalone application.

1. Clone this fork and its OpenFX headers:

   ```sh
   git clone --recurse-submodules https://github.com/jcpsimmons/ntsc-rs.git
   cd ntsc-rs
   ```

2. Build the portable Apple Silicon package:

   ```sh
   bash scripts/build-metal-ofx.sh
   ```

   This creates `target/ntsc-rs-metal-arm64.pkg` and a ZIP under `target/metal-upstream-release/`. Use `--native` only for a build intended for the Mac doing the compilation.

3. Quit Resolve. Move any older experimental `NtscRsMetal.ofx.bundle` out of `/Library/OFX/Plugins`, then install the generated package. It replaces `NtscRs.ofx.bundle` and keeps the existing plugin identifier. Keep one NTSC-rs bundle in the host's plugin search paths.

4. Restart Resolve and select **NTSC-rs Metal**. Existing projects using the original plugin identifier can use the replacement. Test a short section with your settings before committing to a long export.

This remains experimental. Sustained long-form rendering and other OFX hosts need more testing. The scratch cache retains at most about 380 MiB at 4K, with additional allocations possible during concurrent rendering. Heavy snow presets can be limited by CPU metadata generation. Unsupported GPU layouts return an error; CPU rendering is available when the host does not enable Metal.

## Proposed upstream

The work is split so the smaller CPU changes can land independently:

- [#840: Enable CPU threading in OpenFX](https://github.com/ntsc-rs/ntsc-rs/pull/840)
- [#841: Optional AArch64 NEON row filtering](https://github.com/ntsc-rs/ntsc-rs/pull/841)
- [#842: Apple Silicon Metal rendering](https://github.com/ntsc-rs/ntsc-rs/pull/842), a draft that includes both CPU changes

The fork keeps a usable integration while the upstream maintainers review the proposals. The Metal PR still needs broader host, resource-lifetime, and packaging review. It is not an official upstream release.

## Original project

NTSC-rs emulates NTSC and VHS video artifacts. The upstream project also provides After Effects/Premiere plugins and a standalone application. Its [website and documentation](https://ntsc.rs) and [official releases](https://github.com/ntsc-rs/ntsc-rs/releases) remain the reference for those builds. Official upstream downloads do not contain this fork's pending Metal changes.

NTSC-rs is a Rust port of [ntscqt](https://github.com/JargeZ/ntscqt), which was based on [ntsc](https://github.com/zhuker/ntsc) and [composite-video-simulator](https://github.com/joncampbell123/composite-video-simulator). All original license notices and attribution remain in the repository.
