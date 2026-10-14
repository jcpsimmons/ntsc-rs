# OpenFX 4K performance

The OpenFX plugin in v0.9.6 builds without the core library's `rayon` feature. That disables CPU multithreading throughout the effect, even though the code calls methods named `par_for_each`. Enabling that feature in the plugin dependency produced a 6.9x speedup for the 4K benchmark on an Apple M4 Max.

The change is one line in `crates/openfx-plugin/Cargo.toml`. It keeps the core library's default features intact for other consumers.

## Measured results

Tested on 2026-10-13 with a 16-core Apple M4 Max, 64 GiB RAM, and rustc 1.93.1. Each result below is the median of three run medians. Each run measures 30 frames after three warmup frames. Serial and parallel runs were alternated; other desktop apps remained running. These are indicative workstation measurements, not an isolated laboratory benchmark.

| Frame size | Serial | Parallel | Speedup |
| --- | ---: | ---: | ---: |
| 3840 x 2160 | 117.344 ms | 17.019 ms | 6.89x |
| 1920 x 1080 | 30.966 ms | 6.457 ms | 4.80x |
| 854 x 480 | 6.107 ms | 2.577 ms | 2.37x |

The 4K result corresponds to about 8.5 versus 58.8 frames per second for this workload. It does not establish Resolve playback or export speed. Resolve adds media decoding, other effects, host memory management, transfers, compositing, and encoding. The user's actual preset was not measured.

The benchmark uses deterministic float RGBX input, the release's default effect settings, interleaved fields, and sRGB gamma conversion disabled. It follows the plugin's input conversion, effect, and output conversion calls. Scratch allocation, explicit clearing, and freeing are included, using the Rust allocator instead of the OFX host's allocator. Source generation, output hashing, and writing comparison files are outside the timed section. Stage medians do not necessarily sum to the median total.

Raw measurements: [threading-v0.9.6.csv](threading-v0.9.6.csv).

## Release and output verification

The installed plugin binary matched the official v0.9.6 macOS OpenFX package byte for byte. Both had SHA-256 `38fdad605b9f7ff30aee99bf3c9d053f94a8182748628e0748b7a1fc1de75883`.

This branch starts at release commit `0bc9bb8a58d8c69ed7d83fe78ad892a6c7e0e6ec`. Newer upstream commits change effect settings and processing, so this fix uses the installed release as its base. The measured comparison is between local serial and parallel builds of that release's core, not a timing of the installed binary inside Resolve.

Five serial/parallel output comparisons were byte-identical: a 3840 x 2160 interleaved frame, and 853 x 479 frames using interleaved, both-field, and both alternating-field parities. The comparison covers the final frame of each run and the RGB channels; the unused RGBX channel is excluded. This supports the threading change for those cases and is not exhaustive coverage of every preset or host.

The core test suite passed all 66 tests with threading enabled. The ARM64 release OFX bundle built successfully. An in-process library load and plugin descriptor check are recorded separately from actual host rendering. Resolve rendering has not been tested and the installed plugin has not been replaced.

Output comparison details: [output-checks-v0.9.6.json](output-checks-v0.9.6.json).

## Reproduce

Run from this branch's repository root. The core-only commands keep Cargo from enabling threading through the plugin dependency in the serial baseline.

```sh
cargo run --locked --release -p ntsc-rs --example frame_profile -- 3840 2160 30 target/serial.rgbf32
cargo run --locked --release -p ntsc-rs --example frame_profile --features rayon -- 3840 2160 30 target/parallel.rgbf32
cmp target/serial.rgbf32 target/parallel.rgbf32
cargo test --locked -p ntsc-rs --features rayon
cargo tree --locked -p ntsc-rs-openfx-plugin -e features
```

The example accepts `width height measured_frames output_file field_mode`. Use `-` as the output file to skip writing it. Field modes are `interleaved`, `both`, and `alternating`. Output is CSV, with per-stage and total median milliseconds. Leave `RAYON_NUM_THREADS` unset to use the plugin's physical-core default; setting it allows separate thread-count experiments.

Build an Apple Silicon OFX bundle:

```sh
git submodule update --init crates/openfx-plugin/vendor/openfx
cargo xtask build-ofx-plugin --release --target aarch64-apple-darwin --destdir target/resolve-4k-v0.9.6
```

## Further opportunities

1. **Process the analog effect at a lower resolution, then upscale.** A 1920 x 1080 effect buffer has four times fewer pixels than UHD; 854 x 480 has about 20 times fewer. A plugin option could retain 4K output while reducing the simulation resolution. It would require resampling and visual review because noise, detail, field behavior, and edge geometry can change. The smaller-frame timings above exclude downscaling and upscaling and must not be read as full 4K-output timings. The existing effect scale setting changes simulated artifact size; it does not reduce the working buffer dimensions.

2. **Add a Metal processing path.** The current OFX implementation processes CPU buffers. The vendored OpenFX GPU extension provides Metal buffer and command-queue interfaces, but the plugin does not implement them. A useful port would keep intermediate buffers on the GPU and combine compatible passes. Recursive horizontal filters have dependencies along each scanline; they cannot simply become independent per-pixel shaders. Metal is a larger project with an unmeasured speedup, requiring Resolve host and visual tests.

3. **Reuse scratch allocations after profiling in Resolve.** A full-field 4K YIQ buffer contains four float planes, about 126.6 MiB. The plugin allocates and clears it every frame. The local threaded benchmark spends roughly 1 ms allocating and clearing, so pooling looks secondary to the threading fix. Any pool must support overlapping render calls and host memory lifetime rules.

Upstream's [OpenFX usage notes](https://github.com/ntsc-rs/ntsc-rs/blob/v0.9.6/crates/openfx-plugin/README.md#effect-order-and-transforms) also explain that Resolve can upscale a clip before the effect runs. Applying the effect to an explicitly resized image in Fusion, or in a lower-resolution timeline before upscaling, is an existing workflow option. It changes the working resolution and should be compared visually with the desired look.

Code references: [feature defaults](../../crates/ntscrs/Cargo.toml), [thread dispatch](../../crates/ntscrs/src/thread_pool.rs), [OFX dependency](../../crates/openfx-plugin/Cargo.toml), [OFX render and allocation path](../../crates/openfx-plugin/src/lib.rs), [benchmark](../../crates/ntscrs/examples/frame_profile.rs).
