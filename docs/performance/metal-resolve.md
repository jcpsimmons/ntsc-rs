# NTSC-rs Metal for Resolve

This branch adds an Apple Silicon Metal renderer to the v0.9.6 OpenFX plugin. Three paired exports in DaVinci Resolve Studio 21.1 measured a median **5.77x speedup** on an M4 Max. A 59-frame UHD clip exported in 1.773 seconds with Metal and 10.223 seconds with the official installed plugin.

The effect is named **NTSC-rs Metal**, with a separate plugin ID, `com.jcpsimmons:NtscRsMetal`. Existing projects continue to use the original NTSC-rs effect until it is replaced in the project. This build retains v0.9.6's controls and processing order.

## What changed

- The full image pipeline runs on Metal: RGB/YIQ conversion, recursive filters, modulation and demodulation, noise, field processing, chroma shifts, head switching, tracking artifacts, and VHS processing.
- Recursive filters use a parallel scan across each row. Numerically sensitive filters use a serial recurrence on the GPU to preserve output at extreme settings.
- Resolve supplies the Metal command queue and image buffers. The plugin submits work asynchronously, keeps intermediate image planes on the GPU, and reuses scratch buffers after completion. The cache holds at most two UHD-sized scratch buffers, about 380 MiB in total. Overlapping frames can require additional temporary memory.
- Rust retains filter coefficient generation, seeded random decisions, and sparse snow metadata. The CPU fallback enables Rayon threading and the ARM NEON filter implementation. Native builds also enable CPU-specific code generation and ThinLTO.

## Resolve measurements

Tested on 2026-10-13 using a 16-core M4 Max with 64 GiB RAM, macOS 26.5.2, and Resolve Studio 21.1. The control was the installed official v0.9.6 binary. The Metal build used `target-cpu=native` on this Mac.

Both effects were applied as Fusion OFX nodes to the same 3840 x 2160, 30 fps synthetic clip. The source was two seconds; the test timeline contained 59 frames. Each export used H.264 at 20 Mbps with no audio. Render caching was disabled. Paired runs used seeds 0, 1, and 2, and the final pair reversed the order. Times are Resolve's reported render durations.

| Paired run | Official v0.9.6 | Metal |
| --- | ---: | ---: |
| Seed 0 | 10.206 s | 1.787 s |
| Seed 1 | 10.379 s | 1.727 s |
| Seed 2 | 10.223 s | 1.773 s |
| Median | 10.223 s | 1.773 s |

The median corresponds to 5.77 versus 33.28 exported frames per second. These are short, synthetic, default-preset exports. They do not establish interactive playback speed, long-form stability, or performance with every preset and effect stack.

Resolve loaded the separate plugin and logged a successful GPU command completion on the M4 Max. All eight render jobs, including the two PNG comparisons, completed. The MP4 files decoded successfully. Exported comparison frames were visually inspected. Computer-use inspection of Resolve's UI remains uncompleted because the Mac was locked.

Machine-readable host timings, job IDs, binary hashes, and comparison results: [metal-resolve-results.json](metal-resolve-results.json).

## Output checks

A matching frame exported from Resolve as 16-bit RGB PNG differed by at most **1 out of 65,535**. Only 14,158 of 24,883,200 channel samples differed, about 0.057%. This comparison avoids the larger differences that H.264 compression can introduce.

The standalone float comparison covered all field modes, both filter families, all four chroma demodulators, and combinations of VHS, head switching, tracking, snow, ringing, and noise. At UHD, the largest difference among the 16 cases was 0.000032961. The default preset's maximum difference was approximately 0.0000023. GPU output is close to the CPU reference, but it is not bit-identical.

The 67 regular core tests passed. Four explicit GPU tests passed, covering concurrent rendering, padded rows, RGB/RGBA layouts, gamma, field parity, integer formats, and filter scales from 0.125 to 36. Small one-pixel frames also passed the example's comparison suite. Clippy passed with warnings denied, and the core's `no_std` build still passed.

The [UHD parity CSV](metal-parity-4k.csv) records one-frame checks with other desktop activity; its timing columns are not a controlled performance benchmark. A separate [60-frame core benchmark](metal-core-benchmark.csv) measured 17.115 ms for the threaded NEON CPU path and 11.989 ms for Metal using reusable image buffers. This compares Metal against an already optimized CPU implementation, unlike the Resolve comparison against the official release. GPU-only timestamps are unavailable in this direct-buffer mode and are marked `NA`.

## Build and install

Use macOS with Xcode command-line tools and Rust. Initialize the OpenFX submodule, then build:

```sh
git submodule update --init crates/openfx-plugin/vendor/openfx
./scripts/build-metal-ofx.sh
```

This produces `target/metal-release/ntsc-rs-metal-arm64.zip` and `target/ntsc-rs-metal-arm64.pkg`. For a build optimized for the current Mac, use `./scripts/build-metal-ofx.sh --native`; those filenames include `native-arm64`. A native M4 build should not be distributed as a generic Apple Silicon build.

The package installs only `NtscRsMetal.ofx.bundle` in `/Library/OFX/Plugins`. Installation requires normal macOS administrator authorization. The binary is ad-hoc signed; the local installer is unsigned and has not been notarized. Restart Resolve after installation, then select **NTSC-rs Metal** from the OpenFX effects. Copy the desired settings from the original effect. The original bundle is not replaced.

For the recorded host test, Resolve loaded the bundle from the build directory through `OFX_PLUGIN_PATH`. That launch environment was subsequently restored. A permanent system installation has not been performed on the test Mac.

## Reproduce core validation

```sh
cargo test --locked -p ntsc-rs --features metal --lib
cargo test --locked --release -p ntsc-rs --features metal --lib ntsc::metal::tests -- --ignored
NTSC_METAL_DIRECT=1 cargo run --locked --release -p ntsc-rs --features metal --example metal_validate -- 3840 2160 1
NTSC_METAL_DIRECT=1 cargo run --locked --release -p ntsc-rs --features metal --example metal_validate -- 3840 2160 60
cargo clippy --locked -p ntsc-rs -p ntsc-rs-openfx-plugin --features ntsc-rs/metal --lib -- -D warnings
cargo check --locked -p ntsc-rs --no-default-features --features libm,neon-filter
```

The example generates frames in memory and writes only measurements to stdout. The final argument `1` runs the preset comparison suite; larger values benchmark the default preset. It does not write raw frame files.

## Limits and remaining work

Dense snow still requires CPU metadata generation and can reduce or eliminate Metal's advantage over the threaded CPU renderer. Extreme filter scales can also spend more time in the serial GPU recurrence. These cases need separate measurements before making performance claims.

The Metal path currently accepts positive-strided RGB or RGBA images, 8-bit, 16-bit, or float components, and matching full-frame input/output dimensions up to 16,384 pixels per axis. Resolve's ordinary UHD path was tested. Other hosts, Intel Macs, older Apple Silicon devices, interactive playback, and long timelines have not been validated.

The original [CPU threading report](resolve-4k.md) and [Metal kernel experiments](../../experiments/metal/README.md) document earlier stages of the work. Their statements about unimplemented Metal support and untested Resolve rendering describe those earlier stages.
