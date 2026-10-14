# Apple Silicon processing experiments

The next substantial opportunity is a Metal processing backend. The Rust wrapper already compiles to native ARM64 and the existing core uses NEON. Changing the host language does not remove the remaining work. The GPU prototypes here test two expensive parts of that work at full 3840 x 2160 resolution.

These are isolated benchmarks, not a complete NTSC implementation or an OFX GPU backend. The normal plugin build still uses the tested threading fix. The additional CPU filter is behind the opt-in `neon-filter` feature; the plugin does not enable it.

## Full-effect CPU results

Three alternating runs per variant on an M4 Max, 60 measured frames per run after three warmup frames. Values are medians of run medians. Other desktop apps remained running, so small differences should be treated cautiously. All runs produced the same output checksum.

| Variant | Median 4K frame time | Relative to threading fix |
| --- | ---: | ---: |
| Threading fix from the previous branch | 18.684 ms | 1.00x |
| Custom ARM NEON filter | 17.932 ms | 1.04x |
| Custom NEON plus M4 code generation and thin LTO | 17.470 ms | 1.07x |

The custom filter runs four independent rows in NEON lanes and transposes 4 x 4 register tiles to keep memory accesses contiguous. A regression test compares its exact output bits with the original coefficient-vectorized filter for multiple filter orders, 4/8/16 rows, widths through 3840, and delays including values larger than the row width. The full core suite passed 67 tests with one explicitly ignored fixture generator.

This is a modest gain relative to the added architecture-specific code. It is retained as an experiment, with no change to the plugin's default feature selection. Fewer CPU workers also failed to beat the default 16-thread configuration in the initial sweep.

Raw data: [apple-cpu-results.json](apple-cpu-results.json).

## Metal results

These comparisons use one full-resolution float plane. They compare the same input, coefficients, seeds, and operation counts. CPU times use the custom NEON filter and the existing Rayon pool; GPU wall times include command encoding, submission, and waiting for completion. Allocation, shader compilation, fixture reading, and correctness comparisons are outside the timed region. Each median covers 30 measured iterations after three warmups.

| Workload | CPU | Metal wall time | Speedup | Accuracy for the tested fixture |
| --- | ---: | ---: | ---: | --- |
| Ten recursive filter passes | 3.052 ms | 2.068 ms | 1.48x | Maximum absolute error 0.0000053644 |
| Four two-octave noise passes | 6.527 ms | 2.109 ms | 3.09x | Byte-identical float output |

The direct per-scanline Metal filter took 4.373 ms. Transposing the plane before processing made that approach slower still, at 10.852 ms. A GPU port must change the algorithm to expose enough independent work.

The faster filter divides each scanline into 128-pixel blocks. Each lane first calculates its block's response from zero initial state. A parallel affine scan propagates the boundary states, after which each block calculates its output from the resulting initial state. This preserves the mathematical recurrence, but reassociates floating-point calculations. For this fixture, the maximum error after ten passes was 5.3644e-6, RMS error was 1.0713e-6, and 7,529,848 of 8,294,400 floats differed in their bits. This is not a bit-exact algorithm. Its numerical stability must be tested across actual coefficients and presets before use in the plugin.

The noise kernel uses the CPU's hash and simplex formulas. Explicitly disabling implicit floating-point contraction, while retaining the same explicit fused operations as the CPU, made the tested noise output byte-identical. The fixture uses integer-derived seeds, two octaves, frequency 0.05, intensity 0.1, and dyadic row offsets. Arbitrary offsets, all octave counts, other parameter values, and time-varying real presets remain untested.

GPU timer results and error metrics: [metal-results.csv](metal-results.csv).

## What this establishes

The component measurements justify a complete Metal prototype. They do not establish a full-plugin speedup. The full effect contains additional passes, interlacing, scaling semantics, gamma handling, row padding, and host synchronization. CPU sampling identified noise and recursive filtering as major costs, but sampled CPU percentages cannot be converted directly into end-to-end wall-time savings.

The implementation should keep the Rust settings and OFX wrapper, accept the host's Metal buffers and command queue, convert RGB/YIQ on the GPU, and keep intermediate planes there through the simulation. Compatible adjacent operations should share kernels where that preserves the required ordering. Coefficients and small per-row random parameters can be prepared on the CPU without transferring entire image planes. The existing CPU path remains necessary for unsupported hosts and for correctness comparisons.

The [OpenFX Metal interface](https://openfx.readthedocs.io/en/main/Reference/ofxRendering.html) supplies Metal buffers and a host command queue. Integration must obey that queue's ownership and asynchronous rendering rules. The current prototype uses its own queue and waits for each benchmark iteration; it does not test Resolve's queue or host buffers.

Before enabling a Metal path in Resolve, compare the complete effect against CPU output over representative presets, field modes, frame sizes, negative row strides, gamma settings, and overlapping render calls. Then time actual timeline playback and export. The user's regular preset is the preferred compatibility target; the full-frame CPU benchmarks so far use defaults.

## Reproduce

The Metal runner requires macOS 15 or later and Apple Silicon with 32-wide SIMD groups. The scan kernel is deliberately bounded to this 3840-pixel fixture and supports at most 4096 pixels per row. The coefficients and ten-pass workload are fixed: three cascaded one-pole filters with alpha 0.25 and zero initial state. This is not a general filter API.

From the repository root:

```sh
cargo test --locked -p ntsc-rs --features rayon,neon-filter
NTSC_GPU_PROBE_DIR="$PWD/target/metal-fixture" cargo test --locked --release -p ntsc-rs --features rayon,neon-filter metal_filter_fixture -- --ignored --nocapture
clang++ -O3 -std=c++17 -fobjc-arc -framework Foundation -framework Metal experiments/metal/filter_probe.mm -o target/metal-filter-probe
target/metal-filter-probe experiments/metal/filter.metal target/metal-fixture
```

The ignored test generates input and reference files and prints CPU medians. The Metal runner checks both GPU command completion and every output float, then prints GPU timing, wall timing, maximum and RMS error, and the number of nonidentical floats. It exits unsuccessfully on a nonfinite output or an absolute error above 1e-5. That tolerance is an experimental gate for these fixtures, not approval of all possible effect output.

To repeat the full-effect CPU experiment:

```sh
cargo run --locked --release -p ntsc-rs --features rayon --example frame_profile -- 3840 2160 60
cargo run --locked --release -p ntsc-rs --features rayon,neon-filter --example frame_profile -- 3840 2160 60
RUSTFLAGS='-C target-cpu=apple-m4' CARGO_PROFILE_RELEASE_LTO=thin CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 cargo run --locked --release -p ntsc-rs --features rayon,neon-filter --example frame_profile -- 3840 2160 60
```

The final command is an M4-specific experiment, not a universal macOS build. Neither these experiments nor the earlier threading-only bundle have replaced the installed Resolve plugin.
