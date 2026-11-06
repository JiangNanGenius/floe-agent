// SPDX-License-Identifier: MPL-2.0
#include "FloeManifold.h"
#include <manifold/manifold.h>
#include <cmath>
#include <algorithm>
#include <map>
#include <tuple>
#include <string>
#include <vector>
#include <new>

struct FloeManifoldContext { manifold::ExecutionContext execution; };
struct FloeManifoldResult {
  int status = 6;
  std::string message = "The mesh operation failed.";
  std::vector<float> xyz;
  std::vector<uint32_t> indices;
  double volume = 0;
};
namespace {
constexpr size_t kMaxTriangles = 500000;
constexpr size_t kMaxOutputTriangles = 1000000;
bool ingest(FloeManifoldContext& ctx, const float *xyz, size_t vertices,
            const uint32_t *indices, size_t count, manifold::MeshGL& mesh,
            FloeManifoldResult& out) {
  if (!xyz || !indices || !vertices || !count || count % 3 ||
      vertices > 3*kMaxTriangles || count/3 > kMaxTriangles) {
    out.status = 1; out.message = "Use complete triangles within the mesh budget."; return false;
  }
  std::map<std::tuple<float,float,float>, uint32_t> canonical;
  std::vector<uint32_t> remap(vertices);
  mesh.numProp = 3;
  for (size_t i=0;i<vertices;++i) {
    if (ctx.execution.Cancelled()) { out.status=3; out.message="Cancelled."; return false; }
    const float x=xyz[3*i], y=xyz[3*i+1], z=xyz[3*i+2];
    if (!std::isfinite(x)||!std::isfinite(y)||!std::isfinite(z)||
        std::max({std::abs(x),std::abs(y),std::abs(z)})>1e6f) {
      out.status=1; out.message="The mesh has invalid coordinates."; return false;
    }
    auto [it,inserted]=canonical.emplace(std::make_tuple(x,y,z),uint32_t(canonical.size()));
    if (inserted) mesh.vertProperties.insert(mesh.vertProperties.end(),{x,y,z});
    remap[i]=it->second;
  }
  mesh.triVerts.reserve(count);
  for (size_t i=0;i<count;++i) {
    if (indices[i]>=vertices) { out.status=1; out.message="The mesh references a missing vertex."; return false; }
    mesh.triVerts.push_back(remap[indices[i]]);
  }
  return true;
}
bool checked(manifold::Manifold& mesh,FloeManifoldContext& ctx,FloeManifoldResult& out) {
  mesh=mesh.WithContext(ctx.execution);
  const auto status=mesh.Status();
  if (status==manifold::Manifold::Error::Cancelled || ctx.execution.Cancelled()) {
    out.status=3; out.message="Cancelled."; return false;
  }
  if (status!=manifold::Manifold::Error::NoError) {
    out.status=2; out.message="A closed, consistently oriented manifold mesh is required."; return false;
  }
  return true;
}
}
extern "C" {
FloeManifoldContext *floe_manifold_context_create(void) { try { return new FloeManifoldContext; } catch (...) { return nullptr; } }
void floe_manifold_context_cancel(FloeManifoldContext *c) { if(c)c->execution.Cancel(); }
void floe_manifold_context_destroy(FloeManifoldContext *c) { delete c; }
FloeManifoldResult *floe_manifold_boolean(FloeManifoldContext *ctx,
    const float *xyz,size_t vertices,const uint32_t *indices,size_t count,
    const float *toolXYZ,size_t toolVertices,const uint32_t *toolIndices,size_t toolCount,int operation) {
  auto *out=new(std::nothrow) FloeManifoldResult;
  if(!out)return nullptr;
  try {
    if(!ctx || operation<0 || operation>2) { out->status=1; return out; }
    if(ctx->execution.Cancelled()) { out->status=3; out->message="Cancelled."; return out; }
    manifold::MeshGL source;
    if(!ingest(*ctx,xyz,vertices,indices,count,source,*out))return out;
    auto result=ctx->execution.FromMeshGL(source);
    if(!checked(result,*ctx,*out))return out;
    if(toolXYZ) {
      manifold::MeshGL tool;
      if(!ingest(*ctx,toolXYZ,toolVertices,toolIndices,toolCount,tool,*out))return out;
      auto operand=ctx->execution.FromMeshGL(tool);
      if(!checked(operand,*ctx,*out))return out;
      const auto op=operation==0 ? manifold::OpType::Add : operation==1 ? manifold::OpType::Subtract : manifold::OpType::Intersect;
      result=result.Boolean(operand,op);
      if(!checked(result,*ctx,*out))return out;
    }
    if(result.IsEmpty()) { out->status=4; out->message="The operation produces an empty body."; return out; }
    if(result.NumTri()>kMaxOutputTriangles) { out->status=5; out->message="The result exceeds the triangle budget."; return out; }
    auto mesh=result.GetMeshGL();
    if(ctx->execution.Cancelled()) { out->status=3; out->message="Cancelled."; return out; }
    out->xyz.reserve(3*mesh.NumVert());
    for(size_t i=0;i<mesh.NumVert();++i) {
      const auto p=mesh.GetVertPos(i); out->xyz.insert(out->xyz.end(),{p.x,p.y,p.z});
    }
    out->indices=std::move(mesh.triVerts);
    out->volume=result.Volume(); out->status=0; out->message="";
  } catch(const std::exception& e) { out->status=6; out->message=e.what(); }
    catch(...) { out->status=6; }
  return out;
}
int floe_manifold_result_status(const FloeManifoldResult *r) { return r?r->status:6; }
const char *floe_manifold_result_message(const FloeManifoldResult *r) { return r?r->message.c_str():"The mesh kernel is unavailable."; }
size_t floe_manifold_result_vertex_count(const FloeManifoldResult *r) { return r?r->xyz.size()/3:0; }
size_t floe_manifold_result_index_count(const FloeManifoldResult *r) { return r?r->indices.size():0; }
const float *floe_manifold_result_xyz(const FloeManifoldResult *r) { return r?r->xyz.data():nullptr; }
const uint32_t *floe_manifold_result_indices(const FloeManifoldResult *r) { return r?r->indices.data():nullptr; }
double floe_manifold_result_volume(const FloeManifoldResult *r) { return r?r->volume:0; }
void floe_manifold_result_destroy(FloeManifoldResult *r) { delete r; }
}
