#include "include/FloeMeshingNative.h"
#include <mystdlib.h>
#include <meshing.hpp>
#include <core/taskmanager.hpp>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <map>
#include <mutex>
#include <set>
#include <sstream>
#include <thread>
#ifdef OCCGEOMETRY
#include <occgeom.hpp>
#include <BRepTools.hxx>
#include <BRep_Builder.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <TopExp.hxx>
#include <TopoDS.hxx>
#endif

namespace {
struct Failure : std::runtime_error { int code; Failure(int c,const std::string &s):std::runtime_error(s),code(c){} };
void require(bool condition,const char *message) { if(!condition)throw Failure(1,message); }
using Edge=std::array<int,2>;
Edge edge(int a,int b) { return {std::min(a,b),std::max(a,b)}; }
struct Triangle { std::array<int,3> node;int region,tag; };
struct Entity { int kind,index;std::string source,region; };
std::mutex meshingMutex;
}

struct FloeMeshingSession {
    std::atomic<bool> cancelled{false};
    std::string error,brep,prefix;
    double scale=1;
    std::vector<double> inputXYZ,xyz;
    std::vector<Triangle> inputTriangles;
    std::vector<std::string> inputRegions,inputBoundaries,regionIDs,boundaryIDs;
    std::vector<int> tetrahedra,regions,triangles,boundaries;
    std::vector<Entity> entities;
    std::map<std::string,double> local;
    int nodeLimit=200000,elementLimit=1000000;
    void check() const { if(cancelled.load())throw Failure(4,"Native meshing was cancelled."); }
};

namespace {
// Set only while the single native mesher holds meshingMutex. The upstream
// allocation guards execute on that same serial worker.
FloeMeshingSession *active=nullptr;
template<class F>int guarded(FloeMeshingSession *s,F action) {
    if(!s)return 1;
    try{s->error.clear();s->check();action();return 0;}
    catch(const Failure &e){s->error=e.what();return e.code;}
#ifdef OCCGEOMETRY
    catch(const Standard_Failure &e){s->error=e.GetMessageString();return s->cancelled.load()?4:3;}
#endif
    catch(const std::bad_alloc &){s->error="Meshing exceeded available memory.";return 5;}
    catch(const std::exception &e){s->error=e.what();return s->cancelled.load()?4:3;}
    catch(...){s->error="Unknown native meshing failure.";return s->cancelled.load()?4:3;}
}
void checkCount(int kind,int count) {
    if(!active)return;active->check();
    int64_t limit=kind==0?active->nodeLimit:int64_t(active->elementLimit)*(kind==2?4:1);
    if(count<0||count>limit)throw Failure(5,"The mesh exceeded its node or element budget.");
}
void verifyClosed(const std::vector<Triangle> &faces) {
    std::map<std::pair<int,Edge>,std::pair<int,int>> incidence;
    for(const auto &face:faces)for(int i=0;i<3;++i){int a=face.node[i],b=face.node[(i+1)%3];auto &count=incidence[{face.region,edge(a,b)}];count.first++;count.second+=a<b?1:-1;}
    for(const auto &[key,count]:incidence)require(count.first==2&&count.second==0,"The surface must be closed, manifold and consistently outward oriented in every region.");
}
void refine(FloeMeshingSession &s,std::vector<double> &xyz,std::vector<Triangle> &faces,double maximum) {
    for(int pass=0;pass<32;++pass){
        s.check();std::set<Edge> marked;
        for(const auto &face:faces){auto local=s.local.find(s.inputBoundaries[face.tag]);double h=local==s.local.end()?maximum:local->second;for(int i=0;i<3;++i){int a=face.node[i],b=face.node[(i+1)%3];double squared=0;for(int j=0;j<3;++j)squared+=std::pow(xyz[3*a+j]-xyz[3*b+j],2);if(squared>h*h*(1+1e-12))marked.insert(edge(a,b));}}
        if(marked.empty())return;
        if(xyz.size()/3+marked.size()>size_t(s.nodeLimit))throw Failure(5,"Surface refinement exceeds the node budget.");
        std::map<Edge,int> midpoint;
        for(auto e:marked){int index=int(xyz.size()/3);midpoint[e]=index;for(int j=0;j<3;++j)xyz.push_back((xyz[3*e[0]+j]+xyz[3*e[1]+j])*0.5);}
        std::vector<Triangle> next;next.reserve(faces.size()*2);
        for(auto face:faces){
            auto n=face.node;std::array<int,3> m;int count=0;
            for(int i=0;i<3;++i){auto it=midpoint.find(edge(n[i],n[(i+1)%3]));m[i]=it==midpoint.end()?-1:it->second;count+=m[i]>=0;}
            auto add=[&](int a,int b,int c){next.push_back({{a,b,c},face.region,face.tag});checkCount(2,int(next.size()));};
            if(count==0)add(n[0],n[1],n[2]);
            else if(count==3){add(n[0],m[0],m[2]);add(m[0],n[1],m[1]);add(m[2],m[1],n[2]);add(m[0],m[1],m[2]);}
            else {
                int rotation=0;while(!(m[rotation]>=0&&(count==1||m[(rotation+1)%3]>=0)))rotation++;
                int a=n[rotation],b=n[(rotation+1)%3],c=n[(rotation+2)%3],ab=m[rotation];
                if(count==1){add(a,ab,c);add(ab,b,c);}
                else{int bc=m[(rotation+1)%3];add(b,bc,ab);add(a,ab,c);add(ab,bc,c);}
            }
        }
        faces=std::move(next);
    }
    throw Failure(5,"Surface refinement exceeded its subdivision budget.");
}
std::shared_ptr<netgen::Mesh> surfaceMesh(FloeMeshingSession &s,netgen::MeshingParameters &parameters) {
    verifyClosed(s.inputTriangles);auto xyz=s.inputXYZ;auto faces=s.inputTriangles;refine(s,xyz,faces,parameters.maxh);
    auto mesh=std::make_shared<netgen::Mesh>();mesh->SetDimension(3);mesh->SetGlobalH(parameters.maxh);mesh->SetMinimalH(parameters.minh);
    for(size_t i=0;i<xyz.size();i+=3)mesh->AddPoint(netgen::Point3d(xyz[i],xyz[i+1],xyz[i+2]));
    mesh->SetNBCNames(int(s.inputBoundaries.size()));for(size_t i=0;i<s.inputBoundaries.size();++i)mesh->SetBCName(int(i),s.inputBoundaries[i]);
    std::map<std::pair<int,int>,int> descriptors;
    for(const auto &face:faces){auto key=std::make_pair(face.tag,face.region);auto it=descriptors.find(key);int descriptor;if(it==descriptors.end()){netgen::FaceDescriptor fd(face.tag+1,face.region+1,0,0);fd.SetBCProperty(face.tag+1);fd.SetBCName(s.inputBoundaries[face.tag]);descriptor=mesh->AddFaceDescriptor(fd);descriptors[key]=descriptor;}else descriptor=it->second;netgen::Element2d element(3);for(int j=0;j<3;++j)element[j]=face.node[j]+1;element.SetIndex(descriptor);mesh->AddSurfaceElement(element);}
    for(size_t i=0;i<s.inputRegions.size();++i)mesh->SetMaterial(int(i)+1,s.inputRegions[i]);
    mesh->CalcLocalH(parameters.grading);s.check();
    auto status=netgen::MeshVolume(parameters,*mesh);s.check();if(status!=netgen::MESHING3_OK)throw Failure(3,"Netgen could not fill the closed surface.");
    netgen::RemoveIllegalElements(*mesh);netgen::OptimizeVolume(parameters,*mesh);s.check();s.regionIDs=s.inputRegions;return mesh;
}

#ifdef OCCGEOMETRY
std::shared_ptr<netgen::Mesh> brepMesh(FloeMeshingSession &s,netgen::MeshingParameters &parameters) {
    TopoDS_Shape original;BRep_Builder builder;std::istringstream stream(s.brep);BRepTools::Read(original,stream,builder);
    require(!original.IsNull()&&BRepCheck_Analyzer(original,true).IsValid(),"The B-rep is invalid.");
    TopTools_IndexedMapOfShape faces,solids,edges;TopExp::MapShapes(original,TopAbs_FACE,faces);TopExp::MapShapes(original,TopAbs_SOLID,solids);TopExp::MapShapes(original,TopAbs_EDGE,edges);
    require(solids.Extent()>0&&faces.Extent()>0,"A solid B-rep is required.");
    gp_Trsf units;units.SetScale(gp_Pnt(0,0,0),s.scale);BRepBuilderAPI_Transform transform(original,units,false);TopoDS_Shape shape=transform.Shape();
    auto converted=[&](const TopoDS_Shape &value){return transform.ModifiedShape(value);};
    std::set<std::string> matched;
    for(int kind=0;kind<3;++kind){auto &map=kind==0?faces:(kind==1?solids:edges);for(int i=1;i<=map.Extent();++i){auto found=std::find_if(s.entities.begin(),s.entities.end(),[&](const Entity &e){return e.kind==kind&&e.index==i;});std::string id=found==s.entities.end()?s.prefix+(kind==0?"/face/":kind==1?"/solid/":"/edge/")+std::to_string(i):found->source;auto &properties=netgen::OCCGeometry::GetProperties(converted(map(i)));properties.name=kind==1?(found==s.entities.end()?"body":found->region):id;auto local=s.local.find(id);if(local!=s.local.end()){properties.maxh=local->second;matched.insert(id);}}}
    for(const auto &entity:s.entities){int count=entity.kind==0?faces.Extent():entity.kind==1?solids.Extent():edges.Extent();require(entity.index<=count,"A CAD entity index is outside this exact B-rep.");}
    for(const auto &[id,size]:s.local)require(matched.count(id)!=0,"A local mesh size refers to a missing CAD entity.");
    auto geometry=std::make_shared<netgen::OCCGeometry>(shape,3,false);
    auto mesh=std::make_shared<netgen::Mesh>();mesh->SetGeometry(geometry);
    int status=geometry->GenerateMesh(mesh,parameters);s.check();if(status!=0||!mesh)throw Failure(3,"Netgen could not mesh the CAD solid.");
    s.regionIDs.assign(geometry->somap.Extent(),"body");
    for(int i=1;i<=solids.Extent();++i){int domain=geometry->somap.FindIndex(converted(solids(i)));require(domain>0,"A solid lost its source identity during meshing.");s.regionIDs[domain-1]=netgen::OCCGeometry::GetProperties(converted(solids(i))).GetName();}
    return mesh;
}
void clearProperties(){netgen::OCCGeometry::global_shape_property_indices.Clear();netgen::OCCGeometry::global_shape_properties.clear();netgen::OCCGeometry::global_identification_indices.Clear();netgen::OCCGeometry::global_identifications.clear();}
#endif

void collect(FloeMeshingSession &s,const netgen::Mesh &mesh) {
    require(mesh.GetNP()>0&&mesh.GetNE()>0,"The native mesher returned no volume elements.");checkCount(0,int(mesh.GetNP()));checkCount(1,int(mesh.GetNE()));
    s.xyz.clear();s.tetrahedra.clear();s.regions.clear();s.triangles.clear();s.boundaries.clear();s.boundaryIDs.clear();
    for(int i=1;i<=mesh.GetNP();++i){const auto &p=mesh.Point(netgen::PointIndex(i));s.xyz.insert(s.xyz.end(),{p[0],p[1],p[2]});}
    for(int i=0;i<mesh.GetNE();++i){const auto &element=mesh.VolumeElement(netgen::ElementIndex(i));require(element.GetNP()==4,"The native mesher returned a non-tetrahedral volume element.");int domain=element.GetIndex()-1;require(domain>=0&&domain<int(s.regionIDs.size()),"A volume element has no material-region identity.");for(int j=0;j<4;++j)s.tetrahedra.push_back(int(element[j])-1);s.regions.push_back(domain);}
    std::map<std::string,int> tagIndices;
    for(int i=0;i<mesh.GetNSE();++i){const auto &element=mesh.SurfaceElement(netgen::SurfaceElementIndex(i));require(element.GetNP()==3,"The native mesher returned a non-triangular boundary.");auto id=mesh.GetFaceDescriptor(element.GetIndex()).GetBCName();require(!id.empty()&&id!="default","A boundary lost its source identity during meshing.");auto it=tagIndices.find(id);int tag;if(it==tagIndices.end()){tag=int(s.boundaryIDs.size());s.boundaryIDs.push_back(id);tagIndices[id]=tag;}else tag=it->second;for(int j=0;j<3;++j)s.triangles.push_back(int(element[j])-1);s.boundaries.push_back(tag);}
}
}

extern "C" {
void floe_meshing_budget_check(int kind,int count){checkCount(kind,count);}
FloeMeshingSession *floe_mesh_create(void){try{return new FloeMeshingSession;}catch(...){return nullptr;}}
void floe_mesh_destroy(FloeMeshingSession *s){delete s;}
const char *floe_mesh_version(void){return "Netgen 6.2.2507 / floe-meshing 2";}
int floe_mesh_supports_brep(void){
#ifdef OCCGEOMETRY
return 1;
#else
return 0;
#endif
}
const char *floe_mesh_error(const FloeMeshingSession *s){return s?s->error.c_str():"Missing meshing session.";}
void floe_mesh_cancel(FloeMeshingSession *s){if(s)s->cancelled.store(true);}
int floe_mesh_set_brep(FloeMeshingSession *s,const uint8_t *bytes,size_t length,double scale,const char *prefix){return guarded(s,[&]{require(bytes&&length>0&&length<=64000000&&std::isfinite(scale)&&scale>0&&prefix&&*prefix,"Invalid B-rep representation or units.");s->brep.assign(reinterpret_cast<const char *>(bytes),length);s->prefix=prefix;s->scale=scale;});}
int floe_mesh_set_entity(FloeMeshingSession *s,int kind,int index,const char *source,const char *region){return guarded(s,[&]{require(kind>=0&&kind<=2&&index>0&&source&&*source&&region&&*region&&s->entities.size()<1000000,"Invalid CAD entity tag.");s->entities.push_back({kind,index,source,region});});}
int floe_mesh_set_local_size(FloeMeshingSession *s,const char *source,double meters){return guarded(s,[&]{require(source&&*source&&std::isfinite(meters)&&meters>0,"Invalid local mesh size.");s->local[source]=meters;});}
int floe_mesh_set_surface(FloeMeshingSession *s,const double *xyz,int nodes,const int *triangles,int faces,const int *regions,const char *const *regionIDs,int nr,const int *tags,const char *const *boundaryIDs,int nb){return guarded(s,[&]{
    require(xyz&&triangles&&regions&&regionIDs&&tags&&boundaryIDs&&nodes>=4&&nodes<=200000&&faces>=4&&faces<=2000000&&nr>0&&nr<=4096&&nb>0&&nb<=1000000,"Invalid surface representation or budget.");
    for(int i=0;i<nodes*3;++i)require(std::isfinite(xyz[i]),"Non-finite surface coordinate.");for(int i=0;i<faces*3;++i)require(triangles[i]>=0&&triangles[i]<nodes,"Invalid surface connectivity.");
    std::vector<Triangle> input;for(int i=0;i<faces;++i){require(regions[i]>=0&&regions[i]<nr&&tags[i]>=0&&tags[i]<nb,"Invalid surface region or boundary.");input.push_back({{triangles[3*i],triangles[3*i+1],triangles[3*i+2]},regions[i],tags[i]});}
    std::vector<std::string> regionNames,boundaryNames;for(int i=0;i<nr;++i){require(regionIDs[i]&&*regionIDs[i],"Empty surface region identity.");regionNames.emplace_back(regionIDs[i]);}for(int i=0;i<nb;++i){require(boundaryIDs[i]&&*boundaryIDs[i],"Empty source face identity.");boundaryNames.emplace_back(boundaryIDs[i]);}
    s->inputXYZ.assign(xyz,xyz+nodes*3);s->inputTriangles=std::move(input);s->inputRegions=std::move(regionNames);s->inputBoundaries=std::move(boundaryNames);
});}
int floe_mesh_run(FloeMeshingSession *s,double maximum,double minimum,double growth,int curvature,int nodes,int elements){return guarded(s,[&]{
    require(std::isfinite(maximum)&&std::isfinite(minimum)&&maximum>=minimum&&minimum>0&&std::isfinite(growth)&&growth>0&&growth<=1&&nodes>0&&elements>0,"Invalid meshing parameters.");
    std::lock_guard<std::mutex> lock(meshingMutex);s->check();s->nodeLimit=std::min(nodes,200000);s->elementLimit=std::min(elements,1000000);active=s;ngcore::multithread.terminate=0;ngcore::TaskManager::SetNumThreads(1);
    std::atomic<bool> stopped{false};std::thread watcher([&]{while(!stopped.load()){if(s->cancelled.load())ngcore::multithread.terminate=1;std::this_thread::sleep_for(std::chrono::milliseconds(10));}});
    struct Cleanup { std::atomic<bool> &stopped;std::thread &watcher;~Cleanup(){stopped.store(true);watcher.join();active=nullptr;ngcore::multithread.terminate=0;
#ifdef OCCGEOMETRY
        clearProperties();
#endif
    }} cleanup{stopped,watcher};
    netgen::MeshingParameters parameters;parameters.maxh=maximum;parameters.minh=minimum;parameters.grading=growth;parameters.curvaturesafety=curvature?2:0.01;parameters.segmentsperedge=1;parameters.parthread=false;parameters.secondorder=false;parameters.quad=false;
    for(const auto &[id,size]:s->local)require(size>=minimum&&size<=maximum,"A local size is outside the meshing bounds.");
    std::shared_ptr<netgen::Mesh> mesh;
    if(!s->brep.empty()){
#ifdef OCCGEOMETRY
        mesh=brepMesh(*s,parameters);
#else
        throw Failure(2,"This host has no OCCT slice; use a tagged closed surface or an iOS host for B-rep meshing.");
#endif
    }else{for(const auto &[id,size]:s->local)require(std::find(s->inputBoundaries.begin(),s->inputBoundaries.end(),id)!=s->inputBoundaries.end(),"A local size refers to a missing surface face.");mesh=surfaceMesh(*s,parameters);}
    s->check();mesh->Compress();collect(*s,*mesh);s->check();
});}
int floe_mesh_node_count(const FloeMeshingSession *s){return s?int(s->xyz.size()/3):0;}
int floe_mesh_element_count(const FloeMeshingSession *s){return s?int(s->regions.size()):0;}
int floe_mesh_face_count(const FloeMeshingSession *s){return s?int(s->boundaries.size()):0;}
int floe_mesh_region_count(const FloeMeshingSession *s){return s?int(s->regionIDs.size()):0;}
int floe_mesh_boundary_count(const FloeMeshingSession *s){return s?int(s->boundaryIDs.size()):0;}
const double *floe_mesh_nodes(const FloeMeshingSession *s){return s?s->xyz.data():nullptr;}
const int *floe_mesh_tetrahedra(const FloeMeshingSession *s){return s?s->tetrahedra.data():nullptr;}
const int *floe_mesh_regions(const FloeMeshingSession *s){return s?s->regions.data():nullptr;}
const int *floe_mesh_triangles(const FloeMeshingSession *s){return s?s->triangles.data():nullptr;}
const int *floe_mesh_boundaries(const FloeMeshingSession *s){return s?s->boundaries.data():nullptr;}
const char *floe_mesh_region_id(const FloeMeshingSession *s,int i){return s&&i>=0&&i<int(s->regionIDs.size())?s->regionIDs[i].c_str():nullptr;}
const char *floe_mesh_boundary_id(const FloeMeshingSession *s,int i){return s&&i>=0&&i<int(s->boundaryIDs.size())?s->boundaryIDs[i].c_str():nullptr;}
}
