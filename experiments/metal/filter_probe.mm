// Isolated recursive-filter feasibility experiment, not a complete NTSC effect or OFX plugin.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

struct Params { uint32_t width, height; };
static constexpr Params dimensions{3840, 2160};
static constexpr size_t pixels = size_t(dimensions.width) * dimensions.height;

static std::vector<float> readPlane(const std::string& path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file || file.tellg() != std::streamoff(pixels * sizeof(float)))
        throw std::runtime_error("Invalid fixture: " + path);
    file.seekg(0);
    std::vector<float> result(pixels);
    file.read(reinterpret_cast<char*>(result.data()), pixels * sizeof(float));
    return result;
}

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc != 3) { fprintf(stderr, "Usage: filter_probe shader.metal fixture_directory\n"); return 2; }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) throw std::runtime_error("Metal device unavailable");
        NSError* error = nil;
        NSString* source = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
        if (!source) throw std::runtime_error([[error description] UTF8String]);
        MTLCompileOptions* options = [MTLCompileOptions new];
        options.mathMode = MTLMathModeSafe;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
        if (!library) throw std::runtime_error([[error description] UTF8String]);
        auto pipeline = [&](NSString* name) {
            id<MTLFunction> function = [library newFunctionWithName:name];
            id<MTLComputePipelineState> result = [device newComputePipelineStateWithFunction:function error:&error];
            if (!result) throw std::runtime_error([[error description] UTF8String]);
            return result;
        };
        auto transpose = pipeline(@"transpose_plane");
        auto rows = pipeline(@"filter_rows");
        auto columns = pipeline(@"filter_columns");
        auto blockStates = pipeline(@"block_states");
        auto scanStates = pipeline(@"scan_states");
        auto blockOutputs = pipeline(@"block_outputs");
        auto simdScan = pipeline(@"filter_simd_scan");
        auto noise = pipeline(@"add_noise");
        if (simdScan.threadExecutionWidth != 32) throw std::runtime_error("Probe requires 32-wide SIMD groups");
        // Calculate A^128 in double precision; the GPU applies the resulting float matrix.
        std::array<double, 9> transitionDouble{1,0,0,0,1,0,0,0,1};
        const std::array<double, 9> transitionOne{2.25,1,0,-1.6875,0,1,.421875,0,0};
        for (int power = 0; power < 128; ++power) {
            std::array<double, 9> next{};
            for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) for (int k = 0; k < 3; ++k)
                next[i*3+j] += transitionOne[i*3+k] * transitionDouble[k*3+j];
            transitionDouble = next;
        }
        std::array<float,9> transition;
        std::copy(transitionDouble.begin(), transitionDouble.end(), transition.begin());
        std::array<float,45> transitions;
        for (int power = 0; power < 5; ++power) {
            std::copy(transitionDouble.begin(), transitionDouble.end(), transitions.begin() + power * 9);
            std::array<double,9> next{};
            for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) for (int k = 0; k < 3; ++k)
                next[i*3+j] += transitionDouble[i*3+k] * transitionDouble[k*3+j];
            transitionDouble = next;
        }
        auto input = readPlane(std::string(argv[2]) + "/input.f32");
        auto reference = readPlane(std::string(argv[2]) + "/reference.f32");
        auto noiseReference = readPlane(std::string(argv[2]) + "/noise-reference.f32");
        id<MTLBuffer> src = [device newBufferWithBytes:input.data() length:pixels * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> a = [device newBufferWithLength:pixels * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> b = [device newBufferWithLength:pixels * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> output = [device newBufferWithLength:pixels * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        size_t blockCount = ((dimensions.width + 127) / 128) * dimensions.height;
        id<MTLBuffer> states = [device newBufferWithLength:blockCount * 3 * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> starts = [device newBufferWithLength:blockCount * 3 * 4 options:MTLResourceStorageModeShared];
        if (!src || !a || !b || !output || !queue || !states || !starts)
            throw std::runtime_error("Metal allocation failed");
        printf("device,layout,gpu_ms,wall_ms,max_absolute_error,rms_error,bit_differences\n");
        for (int layout : {0, 1, 2, 3, 4}) {
            bool transposed = layout == 1;
            std::vector<double> gpuTimes, wallTimes;
            for (int iteration = 0; iteration < 33; ++iteration) {
                @autoreleasepool {
                    auto start = std::chrono::steady_clock::now();
                    id<MTLCommandBuffer> command = [queue commandBuffer];
                    uint32_t noisePass = 0;
                    auto encode = [&](id<MTLComputePipelineState> pso, id<MTLBuffer> in, id<MTLBuffer> out,
                                      Params p, bool isTranspose) {
                        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
                        [encoder setComputePipelineState:pso];
                        [encoder setBuffer:in offset:0 atIndex:0];
                        [encoder setBuffer:out offset:0 atIndex:1];
                        [encoder setBytes:&p length:sizeof(p) atIndex:2];
                        if (pso == scanStates) [encoder setBytes:transition.data() length:sizeof(transition) atIndex:3];
                        if (pso == blockOutputs) [encoder setBuffer:starts offset:0 atIndex:3];
                        if (pso == noise) [encoder setBytes:&noisePass length:sizeof(noisePass) atIndex:3];
                        if (pso == simdScan) {
                            [encoder setBytes:transitions.data() length:sizeof(transitions) atIndex:3];
                            [encoder dispatchThreadgroups:MTLSizeMake(p.height, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
                        } else if (pso == noise) {
                            [encoder dispatchThreads:MTLSizeMake(pixels, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
                        } else if (isTranspose) {
                            [encoder dispatchThreadgroups:MTLSizeMake((p.width + 31) / 32, (p.height + 31) / 32, 1)
                                    threadsPerThreadgroup:MTLSizeMake(32, 8, 1)];
                        } else {
                            size_t threads = (pso == blockStates || pso == blockOutputs) ? blockCount : p.height;
                            [encoder dispatchThreads:MTLSizeMake(threads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
                        }
                        [encoder endEncoding];
                    };
                    id<MTLBuffer> current = src;
                    if (transposed) { encode(transpose, src, a, dimensions, true); current = a; }
                    int passes = layout == 4 ? 4 : 10;
                    for (int pass = 0; pass < passes; ++pass) {
                        noisePass = pass;
                        id<MTLBuffer> next = (current == a) ? b : a;
                        if (!transposed && pass == passes - 1) next = output;
                        if (layout == 2) {
                            encode(blockStates, current, states, dimensions, false);
                            encode(scanStates, states, starts, dimensions, false);
                            encode(blockOutputs, current, next, dimensions, false);
                        } else if (layout == 3) {
                            encode(simdScan, current, next, dimensions, false);
                        } else if (layout == 4) {
                            encode(noise, current, next, dimensions, false);
                        } else {
                            encode(transposed ? columns : rows, current, next, dimensions, false);
                        }
                        current = next;
                    }
                    if (transposed) encode(transpose, current, output, {dimensions.height, dimensions.width}, true);
                    [command commit];
                    [command waitUntilCompleted];
                    if (command.status != MTLCommandBufferStatusCompleted)
                        throw std::runtime_error([[command.error description] UTF8String]);
                    auto end = std::chrono::steady_clock::now();
                    if (iteration >= 3) {
                        gpuTimes.push_back((command.GPUEndTime - command.GPUStartTime) * 1000.0);
                        wallTimes.push_back(std::chrono::duration<double, std::milli>(end - start).count());
                    }
                }
            }
            double maxError = 0, squared = 0;
            size_t different = 0;
            const float* result = static_cast<const float*>(output.contents);
            const auto& expected = layout == 4 ? noiseReference : reference;
            for (size_t i = 0; i < pixels; ++i) {
                if (!std::isfinite(result[i])) throw std::runtime_error("Non-finite GPU result");
                double error = double(result[i]) - expected[i];
                maxError = std::max(maxError, std::abs(error)); squared += error * error;
                different += memcmp(&result[i], &expected[i], sizeof(float)) != 0;
            }
            std::sort(gpuTimes.begin(), gpuTimes.end()); std::sort(wallTimes.begin(), wallTimes.end());
            printf("%s,%s,%.3f,%.3f,%.9g,%.9g,%zu\n", device.name.UTF8String,
                   layout == 4 ? "noise-four-passes" : (layout == 3 ? "simd-scan-128" : (layout == 2 ? "block-scan-128" : (transposed ? "transposed" : "row-major"))), (gpuTimes[14] + gpuTimes[15]) * .5,
                   (wallTimes[14] + wallTimes[15]) * .5, maxError, sqrt(squared / pixels), different);
            if (maxError > 1e-5) return 1;
        }
    }
}
