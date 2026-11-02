// SPDX-License-Identifier: MPL-2.0
#include "FloeXAtlas.h"
#include "xatlas.h"
#include <atomic>
#include <chrono>
#include <cmath>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

struct FXACancel { std::atomic<bool> requested{false}; };
static std::mutex atlasMutex;
struct Run {
    FXACancel *cancel;
    double budgetSeconds;
    std::chrono::steady_clock::time_point started = std::chrono::steady_clock::now();
    int32_t stopStatus() const { return cancel->requested.load(std::memory_order_relaxed) ? 2 : 8; }
    bool stopped() const { return cancel->requested.load(std::memory_order_relaxed) || std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count() >= budgetSeconds; }
};
static bool progress(xatlas::ProgressCategory, int, void *context) {
    return !static_cast<Run *>(context)->stopped();
}
FXACancel *fxa_cancel_create(void) { return new (std::nothrow) FXACancel(); }
void fxa_cancel_request(FXACancel *c) { if (c) c->requested.store(true, std::memory_order_relaxed); }
void fxa_cancel_destroy(FXACancel *c) { delete c; }
static bool validCounts(uint32_t corners, uint32_t resolution, uint32_t padding) {
    return corners > 0 && corners % 3 == 0 && corners <= 150000 && resolution >= 64 && resolution <= 2048 && padding <= 32;
}
static xatlas::PackOptions options(uint32_t resolution, uint32_t padding) {
    xatlas::PackOptions p; p.resolution = resolution; p.padding = padding;
    p.createImage = false; p.bruteForce = false; return p;
}
static int32_t copyResult(const xatlas::Atlas *a, const uint32_t *originalIndices, uint32_t count,
                          const Run &run, float *uvs, uint32_t *charts, uint32_t *w, uint32_t *h) {
    if (run.stopped()) return run.stopStatus();
    if (!a || a->meshCount != 1 || a->atlasCount != 1 || a->width == 0 || a->height == 0) return 4;
    const auto &m = a->meshes[0];
    if (m.indexCount != count || !m.indexArray || !m.vertexArray || !m.chartArray) return 5;
    std::vector<bool> covered(count / 3, false);
    for (uint32_t c = 0; c < m.chartCount; ++c) {
        if (run.stopped()) return run.stopStatus();
        const auto &chart = m.chartArray[c];
        for (uint32_t f = 0; f < chart.faceCount; ++f) {
            const uint32_t face = chart.faceArray[f];
            if (face >= count / 3 || covered[face]) return 5;
            covered[face] = true; charts[face] = c;
        }
    }
    for (bool value : covered) if (!value) return 4;
    for (uint32_t i = 0; i < count; ++i) {
        if ((i & 1023) == 0 && run.stopped()) return 2;
        if (m.indexArray[i] >= m.vertexCount) return 5;
        const auto &v = m.vertexArray[m.indexArray[i]];
        // Never infer input-face coverage from Chart.material (always 0 in
        // this pin), or accept ignored faces whose atlasIndex is -1.
        if (v.xref != (originalIndices ? originalIndices[i] : i) || v.atlasIndex != 0) return 5;
        const float u = v.uv[0] / float(a->width), t = v.uv[1] / float(a->height);
        if (!std::isfinite(u) || !std::isfinite(t)) return 5;
        uvs[2*i] = u; uvs[2*i+1] = t;
    }
    *w = a->width; *h = a->height;
    return run.stopped() ? run.stopStatus() : 0;
}
int32_t fxa_unwrap(const float *positions, const float *normals, uint32_t vertexCount,
                   const uint32_t *indices, uint32_t indexCount, const uint32_t *groups,
                   uint32_t resolution, uint32_t padding, double wallClockLimitSeconds, FXACancel *cancel,
                   float *uvs, uint32_t *charts, uint32_t *w, uint32_t *h) {
    if (!std::isfinite(wallClockLimitSeconds) || wallClockLimitSeconds <= 0 || !positions || !normals || !indices || !groups || !cancel || !uvs || !charts || !w || !h ||
        !validCounts(indexCount, resolution, padding) || vertexCount == 0 || vertexCount > 150000) return 1;
    *w = *h = 0;
    for (uint32_t i=0; i<vertexCount*3; ++i) if (!std::isfinite(positions[i]) || !std::isfinite(normals[i])) return 1;
    for (uint32_t i=0; i<indexCount; ++i) if (indices[i] >= vertexCount) return 1;
    std::unique_lock<std::mutex> lock(atlasMutex, std::try_to_lock);
    if (!lock.owns_lock()) return 7;
    Run run{cancel,wallClockLimitSeconds}; if (run.stopped()) return run.stopStatus();
    try {
        std::unique_ptr<xatlas::Atlas, decltype(&xatlas::Destroy)> atlas(xatlas::Create(), xatlas::Destroy);
        if (!atlas) return 6;
        xatlas::SetProgressCallback(atlas.get(), progress, &run);
        xatlas::MeshDecl d; d.vertexPositionData = positions; d.vertexPositionStride = sizeof(float)*3;
        d.vertexNormalData = normals; d.vertexNormalStride = sizeof(float)*3;
        d.vertexCount = vertexCount; d.indexData = indices; d.indexCount = indexCount;
        d.indexFormat = xatlas::IndexFormat::UInt32; d.faceMaterialData = groups;
        const auto added = xatlas::AddMesh(atlas.get(), d);
        xatlas::AddMeshJoin(atlas.get()); // Join even rejected input; matches qualified cleanup patch.
        if (run.stopped()) return run.stopStatus();
        if (added != xatlas::AddMeshError::Success) return 3;
        xatlas::Generate(atlas.get(), xatlas::ChartOptions(), options(resolution, padding));
        return copyResult(atlas.get(), indices, indexCount, run, uvs, charts, w, h);
    } catch (...) { return 6; }
}
int32_t fxa_pack(const float *input, uint32_t count, const uint32_t *inputCharts,
                 uint32_t resolution, uint32_t padding, double wallClockLimitSeconds, FXACancel *cancel,
                 float *uvs, uint32_t *charts, uint32_t *w, uint32_t *h) {
    if (!std::isfinite(wallClockLimitSeconds) || wallClockLimitSeconds <= 0 || !input || !inputCharts || !cancel || !uvs || !charts || !w || !h || !validCounts(count,resolution,padding)) return 1;
    *w = *h = 0;
    for (uint32_t i=0; i<count*2; ++i) if (!std::isfinite(input[i]) || std::abs(input[i]) > 1000000) return 1;
    std::unique_lock<std::mutex> lock(atlasMutex, std::try_to_lock); if (!lock.owns_lock()) return 7;
    Run run{cancel,wallClockLimitSeconds}; if (run.stopped()) return run.stopStatus();
    try {
        std::unique_ptr<xatlas::Atlas, decltype(&xatlas::Destroy)> atlas(xatlas::Create(),xatlas::Destroy);
        if (!atlas) return 6;
        xatlas::SetProgressCallback(atlas.get(),progress,&run);
        std::vector<uint32_t> indices(count); for (uint32_t i=0;i<count;++i) indices[i]=i;
        xatlas::UvMeshDecl d; d.vertexUvData=input; d.vertexCount=count; d.vertexStride=sizeof(float)*2;
        d.indexData=indices.data(); d.indexCount=count; d.indexFormat=xatlas::IndexFormat::UInt32;
        d.faceMaterialData=inputCharts;
        if (xatlas::AddUvMesh(atlas.get(),d) != xatlas::AddMeshError::Success) return 3;
        // AddUvMesh does not compute its connected charts. PackCharts requires
        // this stage for UV input just as it does for a position mesh.
        xatlas::ComputeCharts(atlas.get());
        if (run.stopped()) return run.stopStatus();
        xatlas::PackCharts(atlas.get(),options(resolution,padding));
        return copyResult(atlas.get(),nullptr,count,run,uvs,charts,w,h);
    } catch (...) { return 6; }
}
