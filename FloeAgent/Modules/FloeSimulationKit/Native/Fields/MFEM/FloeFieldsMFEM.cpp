#include "include/FloeFieldsMFEM.h"
#include "mfem.hpp"
#include <atomic>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr double epsilon0 = 8.8541878128e-12; // CODATA 2018, pinned SI value.
constexpr double pi = 3.14159265358979323846;
struct Failure : std::runtime_error { int status; Failure(int s,const std::string &m):std::runtime_error(m),status(s){} };
struct Medium { double epsilon=0,mu=0,sigma=0,rho=0,c=0,loss=0; bool em=false,acoustic=false; };
struct Boundary { int kind=-1; std::complex<double> value=0; };
std::mutex kernelMutex;
void require(bool ok,const char *message) { if(!ok) throw Failure(kFloeFieldsErrInvalidInput,message); }
bool validNumber(double x) { return std::isfinite(x); }
}

struct FloeFieldsMFEMSession {
    std::atomic<bool> cancelled{false};
    std::string error;
    std::vector<double> xyz;
    std::vector<int> tets,regions,triangles,tags;
    std::vector<std::string> regionIDs,boundaryIDs;
    std::vector<Medium> materials;
    std::map<int,Boundary> em,acoustic;
    double referencePressure=20e-6;
    void check() const { if(cancelled.load()) throw Failure(kFloeFieldsErrCancelled,"The native solve was cancelled."); }
    int region(const char *id) const { for(size_t i=0;i<regionIDs.size();++i) if(id && regionIDs[i]==id) return int(i); throw Failure(kFloeFieldsErrInvalidInput,"Unknown material region."); }
    int boundary(const char *id) const { for(size_t i=0;i<boundaryIDs.size();++i) if(id && boundaryIDs[i]==id) return int(i); throw Failure(kFloeFieldsErrInvalidInput,"Unknown mesh boundary."); }
};

namespace {
template<class F> int guarded(FloeFieldsMFEMSession *s,F action) {
    if(!s) return kFloeFieldsErrInvalidInput;
    try { s->error.clear();s->check();action();return kFloeFieldsOk; }
    catch(const Failure &e) { s->error=e.what();return e.status; }
    catch(const std::bad_alloc &) { s->error="Native allocation exceeded available memory.";return kFloeFieldsErrNoMemory; }
    catch(const std::exception &e) { s->error=e.what();return kFloeFieldsErrSolver; }
    catch(...) { s->error="Unknown native solver failure.";return kFloeFieldsErrSolver; }
}
struct Monitor : mfem::IterativeSolverMonitor {
    FloeFieldsMFEMSession &s;
    explicit Monitor(FloeFieldsMFEMSession &session):s(session){}
    void MonitorResidual(int,double,const mfem::Vector &,bool) override { s.check(); }
};
std::unique_ptr<mfem::Mesh> makeMesh(FloeFieldsMFEMSession &s,int order,bool complex) {
    require(order>=1 && order<=3,"This native artifact supports polynomial orders 1 through 3.");
    const size_t n=(order+1)*(order+2)*(order+3)/6;
    require(!s.tets.empty() && s.tets.size()/4 <= (complex?4000000:16000000)/(n*n),"The polynomial mesh exceeds the native matrix budget.");
    auto mesh=std::make_unique<mfem::Mesh>(3,int(s.xyz.size()/3),int(s.tets.size()/4),int(s.triangles.size()/3),3);
    for(size_t i=0;i<s.xyz.size();i+=3) mesh->AddVertex(s.xyz.data()+i);
    for(size_t i=0;i<s.tets.size()/4;++i) mesh->AddTet(s.tets.data()+4*i,s.regions[i]+1);
    for(size_t i=0;i<s.triangles.size()/3;++i) mesh->AddBdrTriangle(s.triangles.data()+3*i,s.tags[i]+1);
    mesh->FinalizeTopology(false);mesh->Finalize(false,false);s.check();return mesh;
}
void validateDofs(const mfem::FiniteElementSpace &space) { require(space.GetVSize()<=400000,"The polynomial mesh exceeds the native DOF budget."); }
void outputVertices(const mfem::GridFunction &field,double *out) {
    if(!out) return; mfem::Vector values;field.GetNodalValues(values);
    for(int i=0;i<values.Size();++i) { require(validNumber(values[i]),"The solver returned a non-finite vertex value.");out[i]=values[i]; }
}
void solveCG(mfem::OperatorPtr &a,mfem::Vector &b,mfem::Vector &x,double tolerance,int maximum,FloeFieldsMFEMSession &s,double *residual) {
    mfem::GSSmoother preconditioner(*a.As<mfem::SparseMatrix>());
    mfem::CGSolver solver;Monitor monitor(s);solver.SetMonitor(monitor);solver.SetPrintLevel(-1);solver.SetRelTol(tolerance);solver.SetAbsTol(0);solver.SetMaxIter(maximum);
    solver.SetOperator(*a);solver.SetPreconditioner(preconditioner);solver.Mult(b,x);s.check();
    if(!solver.GetConverged()) throw Failure(kFloeFieldsErrSolver,"The electrostatic solve did not converge.");
    mfem::Vector r(b.Size());a->Mult(x,r);r-=b;
    double relative=r.Norml2()/std::max(b.Norml2(),1e-300);
    require(validNumber(relative) && relative<=std::max(tolerance*10,1e-11),"The electrostatic residual failed read-back.");if(residual)*residual=relative;
}
class BoundaryCoefficient final : public mfem::Coefficient {
    mfem::Mesh &mesh;std::function<double(int,int)> evaluate;
public:
    BoundaryCoefficient(mfem::Mesh &m,std::function<double(int,int)> f):mesh(m),evaluate(f){}
    double Eval(mfem::ElementTransformation &t,const mfem::IntegrationPoint &) override {
        int adjacent,info;mesh.GetBdrElementAdjacentElement(t.ElementNo,adjacent,info);
        return evaluate(t.Attribute-1,mesh.GetAttribute(adjacent)-1);
    }
};
void essential(mfem::Mesh &mesh,const std::map<int,Boundary> &boundaries,bool em,mfem::Array<int> &marker) {
    marker.SetSize(mesh.bdr_attributes.Size()?mesh.bdr_attributes.Max():0);marker=0;
    for(auto &[tag,bc]:boundaries) if((em&&(bc.kind==0||bc.kind==4))||(!em&&bc.kind==1)) marker[tag]=1;
}
}

extern "C" {
FloeFieldsMFEMSession *floe_fields_mfem_create(void) { try { return new FloeFieldsMFEMSession; } catch(...) { return nullptr; } }
void floe_fields_mfem_destroy(FloeFieldsMFEMSession *s) { delete s; }
const char *floe_fields_mfem_version(void) { return "MFEM 4.8.0 / floe-fields 2 / serial CPU"; }
void floe_fields_mfem_last_error(const FloeFieldsMFEMSession *s,char *buffer,int capacity) {
    if(!buffer||capacity<=0)return;const std::string message=s?s->error:"Missing native session.";size_t n=std::min(message.size(),size_t(capacity-1));std::memcpy(buffer,message.data(),n);buffer[n]=0;
}
void floe_fields_mfem_cancel(FloeFieldsMFEMSession *s) { if(s)s->cancelled.store(true); }
void floe_fields_mfem_clear_cancel(FloeFieldsMFEMSession *s) { if(s)s->cancelled.store(false); }
void floe_fields_mfem_mesh_sizes(const FloeFieldsMFEMSession *s,int *nodes,int *elements) { if(nodes)*nodes=s?int(s->xyz.size()/3):0;if(elements)*elements=s?int(s->tets.size()/4):0; }

int floe_fields_mfem_set_mesh(FloeFieldsMFEMSession *s,const double *xyz,int nn,const int *tet,int ne,const char *const *regionIDs,const int *regions,int nr,const int *tri,int nt,const char *const *boundaryIDs,const int *tags,int nb) {
    return guarded(s,[&]{
        require(xyz&&tet&&regions&&regionIDs&&tri&&tags&&boundaryIDs&&nn>=4&&nn<=200000&&ne>0&&ne<=1000000&&nt>0&&nt<=2000000&&nr>0&&nr<=4096&&nb>0&&nb<=100000,"Invalid native mesh pointers or budget.");
        for(int i=0;i<nn*3;++i)require(validNumber(xyz[i]),"Non-finite mesh coordinate.");
        for(int i=0;i<ne*4;++i)require(tet[i]>=0&&tet[i]<nn,"Invalid tetrahedron connectivity.");
        for(int i=0;i<nt*3;++i)require(tri[i]>=0&&tri[i]<nn,"Invalid boundary connectivity.");
        for(int i=0;i<ne;++i)require(regions[i]>=0&&regions[i]<nr,"Invalid material region.");
        for(int i=0;i<nt;++i)require(tags[i]>=0&&tags[i]<nb,"Invalid boundary region.");
        for(int e=0;e<ne;++e){auto p=[&](int i,int axis){return xyz[tet[4*e+i]*3+axis]-xyz[tet[4*e]*3+axis];};double d=p(1,0)*(p(2,1)*p(3,2)-p(2,2)*p(3,1))-p(1,1)*(p(2,0)*p(3,2)-p(2,2)*p(3,0))+p(1,2)*(p(2,0)*p(3,1)-p(2,1)*p(3,0));require(validNumber(d)&&d>0,"Tetrahedron Jacobians must be positive.");}
        std::vector<std::string> r,b;for(int i=0;i<nr;++i){require(regionIDs[i]&&*regionIDs[i],"Empty material identity.");r.emplace_back(regionIDs[i]);}for(int i=0;i<nb;++i){require(boundaryIDs[i]&&*boundaryIDs[i],"Empty boundary identity.");b.emplace_back(boundaryIDs[i]);}
        require(std::set<std::string>(r.begin(),r.end()).size()==r.size()&&std::set<std::string>(b.begin(),b.end()).size()==b.size(),"Duplicate region or boundary identity.");
        s->xyz.assign(xyz,xyz+nn*3);s->tets.assign(tet,tet+ne*4);s->regions.assign(regions,regions+ne);s->triangles.assign(tri,tri+nt*3);s->tags.assign(tags,tags+nt);s->regionIDs=std::move(r);s->boundaryIDs=std::move(b);s->materials.assign(nr,Medium{});s->em.clear();s->acoustic.clear();
    });
}
int floe_fields_mfem_add_em_material(FloeFieldsMFEMSession *s,const char *id,double epsilon,double mu,double sigma) {
    return guarded(s,[&]{require(validNumber(epsilon)&&epsilon>0&&validNumber(mu)&&mu>0&&validNumber(sigma)&&sigma>=0,"Invalid electromagnetic material.");auto &m=s->materials[s->region(id)];m.epsilon=epsilon*epsilon0;m.mu=mu;m.sigma=sigma;m.em=true;});
}
int floe_fields_mfem_add_acoustic_medium(FloeFieldsMFEMSession *s,const char *id,double rho,double c,double loss) {
    return guarded(s,[&]{require(validNumber(rho)&&rho>0&&validNumber(c)&&c>0&&validNumber(loss)&&loss>=0,"Invalid acoustic medium.");auto &m=s->materials[s->region(id)];m.rho=rho;m.c=c;m.loss=loss;m.acoustic=true;});
}
int floe_fields_mfem_add_em_boundary(FloeFieldsMFEMSession *s,const char *id,int kind,double real,double imag) {
    return guarded(s,[&]{require(validNumber(real)&&validNumber(imag),"Non-finite electromagnetic boundary.");if((kind!=0&&kind!=1&&kind!=4)||imag!=0)throw Failure(kFloeFieldsErrUnsupported,"Unsupported electrostatic boundary.");s->em[s->boundary(id)]={kind,{real,imag}};});
}
int floe_fields_mfem_add_acoustic_boundary(FloeFieldsMFEMSession *s,const char *id,int kind,double real,double imag) {
    return guarded(s,[&]{require(kind>=0&&kind<=4&&validNumber(real)&&validNumber(imag),"Invalid acoustic boundary.");require(kind!=3||(real>=0&&std::hypot(real,imag)>0),"Acoustic impedance must be nonzero and passive.");s->acoustic[s->boundary(id)]={kind,{real,imag}};});
}
void floe_fields_mfem_set_acoustic_reference_pressure(FloeFieldsMFEMSession *s,double p) { if(s&&validNumber(p)&&p>0)s->referencePressure=p; }

int floe_fields_mfem_solve_electrostatic(FloeFieldsMFEMSession *s,int order,double tolerance,int maximum,double *potential,double *electric,double *flux,double *energy,double *capacitance,double *residual,double *seconds) {
    return guarded(s,[&]{
        std::lock_guard<std::mutex> lock(kernelMutex);s->check();auto start=std::chrono::steady_clock::now();
        require(validNumber(tolerance)&&tolerance>0&&tolerance<1&&maximum>0,"Invalid electrostatic solver settings.");
        for(auto &m:s->materials){require(m.em,"Assign permittivity to every region.");if(m.sigma!=0)throw Failure(kFloeFieldsErrUnsupported,"Conducting volume regions require a conduction model; electrostatics accepts dielectric regions.");}
        auto mesh=makeMesh(*s,order,false);mfem::H1_FECollection collection(order,3);mfem::FiniteElementSpace space(mesh.get(),&collection);validateDofs(space);
        mfem::Array<int> marker,dofs;essential(*mesh,s->em,true,marker);space.GetEssentialTrueDofs(marker,dofs);require(dofs.Size()>0,"Electrostatics needs a prescribed potential on each component.");
        // Every disconnected domain needs an electrode; otherwise zero RHS can
        // conceal a floating, non-unique component from an iterative residual.
        std::vector<int> parent(s->xyz.size()/3);for(size_t i=0;i<parent.size();++i)parent[i]=int(i);
        std::function<int(int)> root=[&](int i){return parent[i]==i?i:parent[i]=root(parent[i]);};
        for(size_t e=0;e<s->tets.size();e+=4)for(int j=1;j<4;++j)parent[root(s->tets[e+j])]=root(s->tets[e]);
        std::set<int> anchored;for(size_t i=0;i<s->tags.size();++i)if(marker[s->tags[i]])for(int j=0;j<3;++j)anchored.insert(root(s->triangles[3*i+j]));for(size_t i=0;i<parent.size();++i)require(anchored.count(root(int(i)))!=0,"An electrostatic domain has no prescribed potential.");
        mfem::Vector eps(int(s->materials.size()));for(int i=0;i<eps.Size();++i)eps[i]=s->materials[i].epsilon;mfem::PWConstCoefficient coefficient(eps);
        mfem::GridFunction x(&space);x=0.0;double minimum=0,maximumVoltage=0;bool first=true;
        for(auto &[tag,bc]:s->em)if(bc.kind==0||bc.kind==4){mfem::Array<int> one(marker.Size());one=0;one[tag]=1;double value=bc.kind==0?0:bc.value.real();mfem::ConstantCoefficient v(value);x.ProjectBdrCoefficient(v,one);if(first){minimum=maximumVoltage=value;first=false;}minimum=std::min(minimum,value);maximumVoltage=std::max(maximumVoltage,value);}
        mfem::LinearForm b(&space);b=0.0;b.Assemble();mfem::BilinearForm a(&space);a.AddDomainIntegrator(new mfem::DiffusionIntegrator(coefficient));a.Assemble();s->check();
        mfem::OperatorPtr A;mfem::Vector X,B;a.FormLinearSystem(dofs,x,b,A,X,B);solveCG(A,B,X,tolerance,maximum,*s,residual);a.RecoverFEMSolution(X,b,x);outputVertices(x,potential);
        double total=0;mfem::Vector gradient(3);
        for(int e=0;e<mesh->GetNE();++e){s->check();auto *t=mesh->GetElementTransformation(e);const auto &rule=mfem::IntRules.Get(mesh->GetElementBaseGeometry(e),2*order+2);double volume=0;mfem::Vector average(3);average=0.0;double epsilon=s->materials[s->regions[e]].epsilon;for(int k=0;k<rule.GetNPoints();++k){const auto &ip=rule.IntPoint(k);t->SetIntPoint(&ip);x.GetGradient(*t,gradient);double w=ip.weight*t->Weight();volume+=w;average.Add(w,gradient);total+=0.5*epsilon*(gradient*gradient)*w;}for(int j=0;j<3;++j){double field=-average[j]/volume;if(electric)electric[3*e+j]=field;if(flux)flux[3*e+j]=epsilon*field;}}
        if(energy)*energy=total;if(capacitance)*capacitance=maximumVoltage>minimum?2*total/((maximumVoltage-minimum)*(maximumVoltage-minimum)):0;
        if(seconds)*seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();s->check();
    });
}

int floe_fields_mfem_solve_acoustic(FloeFieldsMFEMSession *s,double frequency,int order,double tolerance,int maximum,double *pressureReal,double *pressureImag,double *velocityReal,double *velocityImag,double *spl,double *residual,double *seconds) {
    return guarded(s,[&]{
        std::lock_guard<std::mutex> lock(kernelMutex);s->check();auto start=std::chrono::steady_clock::now();require(validNumber(frequency)&&frequency>0&&validNumber(tolerance)&&tolerance>0&&tolerance<1&&maximum>0,"Invalid acoustic solver settings.");for(auto &m:s->materials)require(m.acoustic,"Assign an acoustic medium to every region.");
        auto mesh=makeMesh(*s,order,true);mfem::H1_FECollection collection(order,3);mfem::FiniteElementSpace space(mesh.get(),&collection);validateDofs(space);double omega=2*pi*frequency;
        mfem::Vector diffusion(int(s->materials.size())),mass(diffusion.Size()),loss(diffusion.Size());for(int i=0;i<diffusion.Size();++i){const auto &m=s->materials[i];diffusion[i]=1/m.rho;mass[i]=-omega*omega/(m.rho*m.c*m.c);loss[i]=-mass[i]*m.loss;}mfem::PWConstCoefficient d(diffusion),m(mass),l(loss);
        mfem::Array<int> marker,dofs;essential(*mesh,s->acoustic,false,marker);space.GetEssentialTrueDofs(marker,dofs);
        mfem::ComplexGridFunction x(&space);x=0.0;
        for(auto &[tag,bc]:s->acoustic)if(bc.kind==1){mfem::Array<int> one(marker.Size());one=0;one[tag]=1;mfem::ConstantCoefficient real(bc.value.real()),imag(bc.value.imag());x.ProjectBdrCoefficient(real,imag,one);}
        auto robin=[&](int tag,int region){auto it=s->acoustic.find(tag);if(it==s->acoustic.end())return std::complex<double>(0);auto bc=it->second;if(bc.kind==4)return std::complex<double>(0,omega/(s->materials[region].rho*s->materials[region].c));if(bc.kind==3)return std::complex<double>(0,omega)/bc.value;return std::complex<double>(0);};
        auto excitation=[&](int tag,int){auto it=s->acoustic.find(tag);return it!=s->acoustic.end()&&it->second.kind==2?std::complex<double>(0,-omega)*it->second.value:std::complex<double>(0);};
        BoundaryCoefficient rr(*mesh,[&](int tag,int r){return robin(tag,r).real();}),ri(*mesh,[&](int tag,int r){return robin(tag,r).imag();}),br(*mesh,[&](int tag,int r){return excitation(tag,r).real();}),bi(*mesh,[&](int tag,int r){return excitation(tag,r).imag();});
        mfem::ComplexLinearForm b(&space,mfem::ComplexOperator::HERMITIAN);b.AddBoundaryIntegrator(new mfem::BoundaryLFIntegrator(br),new mfem::BoundaryLFIntegrator(bi));b=0.0;b.Assemble();
        mfem::SesquilinearForm a(&space,mfem::ComplexOperator::HERMITIAN);a.AddDomainIntegrator(new mfem::DiffusionIntegrator(d),nullptr);a.AddDomainIntegrator(new mfem::MassIntegrator(m),new mfem::MassIntegrator(l));a.AddBoundaryIntegrator(new mfem::MassIntegrator(rr),new mfem::MassIntegrator(ri));a.Assemble();s->check();
        mfem::OperatorPtr A;mfem::Vector X,B;a.FormLinearSystem(dofs,x,b,A,X,B);
        // An elliptic |Helmholtz| preconditioner changes only convergence, not
        // the physical operator. No diagonal regularization enters the solve.
        mfem::Vector positiveMass(mass.Size());for(int i=0;i<mass.Size();++i)positiveMass[i]=-mass[i];mfem::PWConstCoefficient pm(positiveMass);
        mfem::BilinearForm pre(&space);pre.AddDomainIntegrator(new mfem::DiffusionIntegrator(d));pre.AddDomainIntegrator(new mfem::MassIntegrator(pm));pre.Assemble();mfem::OperatorPtr P;pre.FormSystemMatrix(dofs,P);mfem::GSSmoother smoother(*P.As<mfem::SparseMatrix>());mfem::ScaledOperator imaginary(&smoother,1);
        mfem::Array<int> offsets(3);offsets[0]=0;offsets[1]=space.GetTrueVSize();offsets[2]=space.GetTrueVSize();offsets.PartialSum();mfem::BlockDiagonalPreconditioner block(offsets);block.SetDiagonalBlock(0,&smoother);block.SetDiagonalBlock(1,&imaginary);
        mfem::GMRESSolver solver;Monitor monitor(*s);solver.SetMonitor(monitor);solver.SetPrintLevel(-1);solver.SetKDim(std::min(100,maximum));solver.SetMaxIter(maximum);solver.SetRelTol(tolerance);solver.SetAbsTol(0);solver.SetOperator(*A);solver.SetPreconditioner(block);solver.Mult(B,X);s->check();if(!solver.GetConverged())throw Failure(kFloeFieldsErrSolver,"The acoustic solve did not converge: iterations="+std::to_string(solver.GetNumIterations())+", initialNorm="+std::to_string(solver.GetInitialNorm())+", finalNorm="+std::to_string(solver.GetFinalNorm()));
        mfem::Vector r(B.Size());A->Mult(X,r);r-=B;double relative=r.Norml2()/std::max(B.Norml2(),1e-300);require(validNumber(relative)&&relative<=std::max(tolerance*10,1e-10),"The acoustic residual failed read-back.");if(residual)*residual=relative;
        a.RecoverFEMSolution(X,b,x);outputVertices(x.real(),pressureReal);outputVertices(x.imag(),pressureImag);
        if(spl){mfem::Vector real,imag;x.real().GetNodalValues(real);x.imag().GetNodalValues(imag);for(int i=0;i<real.Size();++i)spl[i]=20*std::log10(std::max(std::hypot(real[i],imag[i])/std::sqrt(2.0),s->referencePressure*1e-15)/s->referencePressure);}
        mfem::Vector gr(3),gi(3);for(int e=0;e<mesh->GetNE();++e){s->check();auto *t=mesh->GetElementTransformation(e);const auto &rule=mfem::IntRules.Get(mesh->GetElementBaseGeometry(e),2*order+2);double volume=0;mfem::Vector ar(3),ai(3);ar=0.0;ai=0.0;for(int k=0;k<rule.GetNPoints();++k){const auto &ip=rule.IntPoint(k);t->SetIntPoint(&ip);x.real().GetGradient(*t,gr);x.imag().GetGradient(*t,gi);double weight=ip.weight*t->Weight();volume+=weight;ar.Add(weight,gr);ai.Add(weight,gi);}double rho=s->materials[s->regions[e]].rho;for(int j=0;j<3;++j){if(velocityReal)velocityReal[e*3+j]=-ai[j]/(volume*omega*rho);if(velocityImag)velocityImag[e*3+j]=ar[j]/(volume*omega*rho);}}
        if(seconds)*seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();s->check();
    });
}
}
