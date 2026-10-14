#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)

struct Params { uint width; uint height; };

// A padded tile gives coalesced reads and writes on both sides of the transpose.
kernel void transpose_plane(device const float* src [[buffer(0)]],
                            device float* dst [[buffer(1)]],
                            constant Params& p [[buffer(2)]],
                            uint2 group [[threadgroup_position_in_grid]],
                            uint2 local [[thread_position_in_threadgroup]]) {
    threadgroup float tile[32][33];
    uint2 origin = group * 32;
    for (uint dy = 0; dy < 32; dy += 8) {
        uint x = origin.x + local.x, y = origin.y + local.y + dy;
        if (x < p.width && y < p.height) tile[local.y + dy][local.x] = src[y * p.width + x];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint dy = 0; dy < 32; dy += 8) {
        uint x = origin.y + local.x, y = origin.x + local.y + dy;
        if (x < p.height && y < p.width) dst[y * p.height + x] = tile[local.x][local.y + dy];
    }
}

inline void filter_line(device const float* src, device float* dst,
                        constant Params& p, uint row, bool transposed) {
    if (row >= p.height) return;
    float3 z = 0.0f;
    for (uint x = 0; x < p.width; ++x) {
        uint offset = transposed ? x * p.height + row : row * p.width + x;
        float sample = src[offset];
        float value = fma(0.015625f, sample, z.x);
        z = float3(fma(2.25f, value, fma(0.0f, sample, z.y)),
                   fma(-1.6875f, value, fma(0.0f, sample, z.z)),
                   fma(0.421875f, value, fma(0.0f, sample, 0.0f)));
        dst[offset] = value;
    }
}

kernel void filter_rows(device const float* src [[buffer(0)]],
                        device float* dst [[buffer(1)]],
                        constant Params& p [[buffer(2)]],
                        uint row [[thread_position_in_grid]]) {
    filter_line(src, dst, p, row, false);
}

kernel void filter_columns(device const float* src [[buffer(0)]],
                           device float* dst [[buffer(1)]],
                           constant Params& p [[buffer(2)]],
                           uint row [[thread_position_in_grid]]) {
    filter_line(src, dst, p, row, true);
}

constant uint block_width = 128;

// Same ESGTSA hash and 1D simplex formulation as the CPU implementation (adapted from Clatter).
inline uint noise_hash(uint v) {
    v = (v ^ 2747636419u) * 2654435769u;
    v = (v ^ (v >> 16)) * 2654435769u;
    return (v ^ (v >> 16)) * 2654435769u;
}
inline float gradient(uint hash) {
    uint h = hash >> 28;
    float v = float((h & 7) + 1);
    return (h & 8) == 0 ? v : -v;
}
inline float simplex(float point, int seed) {
    float cell = floor(point);
    int i = int(cell);
    float x0 = point - cell, x1 = x0 - 1.0f;
    float t0 = fma(-x0, x0, 1.0f), t1 = fma(-x1, x1, 1.0f);
    float t20 = t0 * t0, t21 = t1 * t1;
    float t40 = t20 * t20, t41 = t21 * t21;
    float gx0 = gradient(noise_hash(uint(i ^ seed)));
    float gx1 = gradient(noise_hash(uint((i + 1) ^ seed)));
    return fma(t40 * gx0, x0, t41 * gx1 * x1);
}
kernel void add_noise(device const float* src [[buffer(0)]],
                      device float* dst [[buffer(1)]],
                      constant Params& p [[buffer(2)]],
                      constant uint& pass [[buffer(3)]],
                      uint id [[thread_position_in_grid]]) {
    if (id >= p.width * p.height) return;
    uint row = id / p.width, x = id % p.width;
    float point = (float(row) * 0.125f + float(x)) * 0.05f;
    int seed = int(row) * 17 + 1234 + int(pass) * 101;
    float noise = fma(simplex(point * 2.0f, seed), 1.0f, simplex(point, seed));
    dst[id] = src[id] + noise * 0.1f;
}

inline float filter_sample(float sample, thread float3& z) {
    float value = fma(0.015625f, sample, z.x);
    z = float3(fma(2.25f, value, fma(0.0f, sample, z.y)),
               fma(-1.6875f, value, fma(0.0f, sample, z.z)),
               fma(0.421875f, value, fma(0.0f, sample, 0.0f)));
    return value;
}

// A block's final state is B + A^128 * initial_state. First measure B independently.
kernel void block_states(device const float* src [[buffer(0)]],
                         device float* states [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         uint id [[thread_position_in_grid]]) {
    uint blocks = (p.width + block_width - 1) / block_width;
    uint row = id / blocks, block = id % blocks;
    if (row >= p.height) return;
    float3 state = 0.0f;
    uint end = min((block + 1) * block_width, p.width);
    for (uint x = block * block_width; x < end; ++x) filter_sample(src[row * p.width + x], state);
    states[id * 3] = state.x; states[id * 3 + 1] = state.y; states[id * 3 + 2] = state.z;
}

// Scan a few block boundaries per row instead of thousands of individual pixels.
kernel void scan_states(device const float* states [[buffer(0)]],
                        device float* starts [[buffer(1)]],
                        constant Params& p [[buffer(2)]],
                        constant float* transition [[buffer(3)]],
                        uint row [[thread_position_in_grid]]) {
    if (row >= p.height) return;
    uint blocks = (p.width + block_width - 1) / block_width;
    float3 state = 0.0f;
    for (uint block = 0; block < blocks; ++block) {
        uint offset = (row * blocks + block) * 3;
        starts[offset] = state.x; starts[offset + 1] = state.y; starts[offset + 2] = state.z;
        float3 next;
        for (uint i = 0; i < 3; ++i) {
            next[i] = fma(transition[i * 3], state.x,
                      fma(transition[i * 3 + 1], state.y,
                      fma(transition[i * 3 + 2], state.z, states[offset + i])));
        }
        state = next;
    }
}

kernel void block_outputs(device const float* src [[buffer(0)]],
                          device float* dst [[buffer(1)]],
                          constant Params& p [[buffer(2)]],
                          device const float* starts [[buffer(3)]],
                          uint id [[thread_position_in_grid]]) {
    uint blocks = (p.width + block_width - 1) / block_width;
    uint row = id / blocks, block = id % blocks;
    if (row >= p.height) return;
    float3 state = float3(starts[id * 3], starts[id * 3 + 1], starts[id * 3 + 2]);
    uint end = min((block + 1) * block_width, p.width);
    for (uint x = block * block_width; x < end; ++x) {
        uint offset = row * p.width + x;
        dst[offset] = filter_sample(src[offset], state);
    }
}

// One SIMD group per scanline. Each lane filters a separate 128-pixel block, then the group
// propagates the block states with a parallel affine scan before writing the final output.
// This probe supports at most 32 blocks per row (4096 pixels) and 32-wide SIMD groups.
kernel void filter_simd_scan(device const float* src [[buffer(0)]],
                             device float* dst [[buffer(1)]],
                             constant Params& p [[buffer(2)]],
                             constant float* transitions [[buffer(3)]],
                             uint row [[threadgroup_position_in_grid]],
                             uint lane [[thread_index_in_simdgroup]]) {
    uint begin = lane * block_width;
    uint end = min(begin + block_width, p.width);
    float3 state = 0.0f;
    for (uint x = begin; x < end; ++x) filter_sample(src[row * p.width + x], state);
    for (uint power = 0; power < 5; ++power) {
        uint offset = 1u << power;
        float3 left = simd_shuffle_up(state, offset);
        if (lane >= offset) {
            float3 next;
            for (uint i = 0; i < 3; ++i) {
                uint base = power * 9 + i * 3;
                next[i] = fma(transitions[base], left.x,
                          fma(transitions[base + 1], left.y,
                          fma(transitions[base + 2], left.z, state[i])));
            }
            state = next;
        }
    }
    state = simd_shuffle_up(state, 1);
    if (lane == 0) state = 0.0f;
    for (uint x = begin; x < end; ++x) {
        uint offset = row * p.width + x;
        dst[offset] = filter_sample(src[offset], state);
    }
}
