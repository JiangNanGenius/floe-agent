#include "FloeChemistryBridge.h"
#include <avogadro/core/molecule.h>
#include <avogadro/core/crystaltools.h>
#include <avogadro/core/unitcell.h>
#include <avogadro/io/fileformatmanager.h>
#include <avogadro/io/smilesparser.h>
#include <avogadro/quantumio/qcschema.h>
#include <avogadro/quantumio/gaussiancube.h>
#include <avogadro/quantumio/molden.h>
#include <avogadro/quantumio/orca.h>
#include <avogadro/calc/uff.h>
#include <avogadro/calc/energyoptimizer.h>
#include <nlohmann/json.hpp>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <stdexcept>

using nlohmann::json;
using Avogadro::Core::Molecule;
struct Cancellation { std::atomic<bool> cancelled{false}; };
static std::mutex nativeMutex;
static int integer(const json &value, int low, int high, const char *name) {
  if(!value.is_number_integer()) throw std::runtime_error(std::string("Expected integer ")+name);
  auto number=value.get<int64_t>();
  if(number<low||number>high) throw std::runtime_error(std::string("Out of range: ")+name);
  return static_cast<int>(number);
}
static bool depthCheck(int depth, json::parse_event_t, json &) {
  if(depth>64) throw std::runtime_error("Chemical JSON nesting exceeds its limit");
  return true;
}
static void check(Cancellation *token) {
  if (token && token->cancelled.load()) throw std::runtime_error("Cancelled");
}
static size_t indexValue(const json &value, const char *key, size_t count) {
  if(!value.at(key).is_number_integer()) throw std::runtime_error("Expected an integer index");
  auto number=value.at(key).get<long long>();
  if(number<0 || static_cast<size_t>(number)>=count) throw std::runtime_error("Atom or bond index is out of range");
  return static_cast<size_t>(number);
}
static Avogadro::Vector3 position(const json &edit) {
  auto p=edit.at("position").get<std::vector<double>>();
  if(p.size()!=3) throw std::runtime_error("Position must contain three coordinates");
  for(auto v:p) if(!std::isfinite(v)||std::abs(v)>1e8) throw std::runtime_error("Invalid coordinate");
  return {p[0],p[1],p[2]};
}
static void edits(Molecule &m, const json &options) {
  const auto &items=options.at("edits");
  if(!items.is_array() || items.size()>10000) throw std::runtime_error("Invalid edit batch");
  for(const auto &e:items) {
    auto op=e.at("op").get<std::string>();
    if(op=="atom.add" || op=="atom.replace") {
      int z=integer(e.at("atomicNumber"),1,118,"atomic number");
      if(op=="atom.add") m.addAtom(z,position(e));
      else m.atom(indexValue(e,"index",m.atomCount())).setAtomicNumber(z);
    } else if(op=="atom.position") m.atom(indexValue(e,"index",m.atomCount())).setPosition3d(position(e));
    else if(op=="atom.remove") {
      if(!m.removeAtom(indexValue(e,"index",m.atomCount()))) throw std::runtime_error("Cannot remove atom");
    } else if(op=="bond.add") {
      auto a=indexValue(e,"a",m.atomCount()),b=indexValue(e,"b",m.atomCount());
      int order=integer(e.value("order",json(1)),1,3,"bond order");
      if(a==b||order<1||order>3||m.bond(a,b).isValid()) throw std::runtime_error("Invalid or duplicate bond");
      m.addBond(a,b,order);
    } else if(op=="bond.remove") {
      if(!m.removeBond(indexValue(e,"a",m.atomCount()),indexValue(e,"b",m.atomCount()))) throw std::runtime_error("Bond not found");
    } else if(op=="bond.order") {
      auto b=m.bond(indexValue(e,"index",m.bondCount()));int order=integer(e.at("order"),1,3,"bond order");
      if(order<1||order>3) throw std::runtime_error("Invalid bond order");
      b.setOrder(order);
    } else throw std::runtime_error("Unsupported edit operation: "+op);
    if(m.atomCount()>100000||m.bondCount()>200000) throw std::runtime_error("Structure exceeds native input limits");
  }
}
static json execute(const json &r, Cancellation *token) {
  check(token);
  const auto operation=r.at("operation").get<std::string>();
  const auto format=r.value("format",std::string("cjson"));
  const auto data=r.at("data").get<std::string>();
  const auto options=r.value("options",json::object());
  Molecule molecule;
  auto &formats=Avogadro::Io::FileFormatManager::instance();
  if(format=="cjson"||format=="qcschema") (void)json::parse(data,depthCheck);
  std::vector<size_t> atomMaps;
  if(format=="smi"||format=="smiles") {
    Avogadro::Io::SmilesParser parser;
    if(!parser.parse(data,molecule)) throw std::runtime_error(parser.error());
    // Upstream explicitly discards stereo descriptors; fail instead of silently changing chemistry.
    if(!parser.warnings().empty()) throw std::runtime_error("This SMILES needs a stereochemistry-preserving backend: "+parser.warnings().front());
    atomMaps=parser.atomMaps();
  } else if(format=="qcschema") {
    Avogadro::QuantumIO::QCSchema input;
    if(!input.readString(data,molecule)) throw std::runtime_error(input.error());
  } else if(format=="cube") {
    Avogadro::QuantumIO::GaussianCube input;
    if(!input.readString(data,molecule)) throw std::runtime_error(input.error());
  } else if(format=="molden") {
    Avogadro::QuantumIO::MoldenFile input;
    if(!input.readString(data,molecule)) throw std::runtime_error(input.error());
  } else if(format=="orca") {
    Avogadro::QuantumIO::ORCAOutput input;
    if(!input.readString(data,molecule)) throw std::runtime_error(input.error());
  } else if(!formats.readString(molecule,data,format)) throw std::runtime_error("Cannot read chemical input: "+formats.error());
  if(molecule.atomCount()>100000||molecule.bondCount()>200000) throw std::runtime_error("Structure exceeds native input limits");
  for(const auto &p:molecule.atomPositions3d()) if(!p.allFinite()||p.cwiseAbs().maxCoeff()>1e8) throw std::runtime_error("Input coordinates exceed the finite coordinate range");
  check(token);
  json result=json::object();
  if(operation=="edit") edits(molecule,options);
  else if(operation=="trajectory.frame") {
    const int frame=integer(options.at("frame"),0,100000,"frame");
    if(static_cast<size_t>(frame)>=molecule.coordinate3dCount()||!molecule.setCoordinate3d(frame)) throw std::runtime_error("Trajectory frame not available");
    result["frame"]=frame;
  } else if(operation=="measure") {
    const auto selected=options.at("atoms");
    if(!selected.is_array()||selected.size()<2||selected.size()>4||molecule.atomPositions3d().size()!=molecule.atomCount()) throw std::runtime_error("Select two to four atoms with 3D coordinates");
    std::vector<Avogadro::Vector3> p;
    for(const auto &item:selected) p.push_back(molecule.atomPositions3d().at(integer(item,0,static_cast<int>(molecule.atomCount())-1,"atom index")));
    result["distance"]=(p[1]-p[0]).norm();result["distanceUnits"]="angstrom";
    if(p.size()>=3) {
      auto u=p[0]-p[1],v=p[2]-p[1];
      if(u.norm()<1e-12||v.norm()<1e-12) throw std::runtime_error("Angle requires distinct positions");
      result["angle"]=std::acos(std::clamp(u.dot(v)/(u.norm()*v.norm()),-1.0,1.0))*180.0/3.141592653589793;
    }
    if(p.size()==4) {
      Avogadro::Vector3 b1=p[1]-p[0],b2=p[2]-p[1],b3=p[3]-p[2],n1=b1.cross(b2),n2=b2.cross(b3);
      if(n1.norm()<1e-12||n2.norm()<1e-12||b2.norm()<1e-12) throw std::runtime_error("Dihedral requires non-collinear reference bonds");
      result["dihedral"]=std::atan2(n1.cross(n2).dot(b2.normalized()),n1.dot(n2))*180.0/3.141592653589793;
    }
    result["angleUnits"]="degree";
  } else if(operation=="crystal.supercell") {
    const int a=integer(options.value("a",json(1)),1,100,"a"),b=integer(options.value("b",json(1)),1,100,"b"),c=integer(options.value("c",json(1)),1,100,"c");
    if(a<1||b<1||c<1||a>100||b>100||c>100||static_cast<uint64_t>(a)*b*c*molecule.atomCount()>100000)
      throw std::runtime_error("Invalid supercell dimensions");
    if(!molecule.unitCell()||!Avogadro::Core::CrystalTools::buildSupercell(molecule,a,b,c)) throw std::runtime_error("A valid unit cell is required");
  } else if(operation=="uff.energy"||operation=="uff.optimize") {
    if(molecule.atomCount()==0||molecule.atomCount()>2000) throw std::runtime_error("UFF requires 1–2000 atoms in this native implementation");
    const auto &coords=molecule.atomPositions3d();
    if(coords.size()!=molecule.atomCount()) throw std::runtime_error("Three-dimensional coordinates are required");
    Eigen::VectorXd x(coords.size()*3);
    for(size_t i=0;i<coords.size();++i) for(int k=0;k<3;++k) {
      auto v=coords[i][k];if(!std::isfinite(v)) throw std::runtime_error("Invalid input coordinate"); x[i*3+k]=v;
    }
    Avogadro::Calc::UFF method;method.setMolecule(&molecule);
    double initial=method.value(x);
    if(!std::isfinite(initial)) throw std::runtime_error("UFF could not evaluate this structure");
    result["initialEnergy"]=initial;result["units"]="kJ/mol";
    size_t performed=0;bool converged=false;std::string stop="evaluated";
    if(operation=="uff.optimize") {
      const int limit=integer(options.value("iterations",json(200)),1,10000,"iterations");const double tolerance=options.value("tolerance",1e-4);
      if(limit<1||limit>10000||!std::isfinite(tolerance)||tolerance<=0) throw std::runtime_error("Invalid optimization limits");
      Avogadro::Calc::OptimizationOptions opt;Avogadro::Calc::OptimizerState state;
      while(performed<static_cast<size_t>(limit)) {
        check(token);opt.chunkIterations=std::min<size_t>(5,limit-performed);
        if(!Avogadro::Calc::optimizeSteps(method,x,opt,&state)) throw std::runtime_error("Optimization options were rejected");
        performed+=state.iterationsRun;
        if(!x.allFinite()||!std::isfinite(state.energy)||!state.gradient.allFinite()) throw std::runtime_error("Optimization produced non-finite values");
        if(state.gradient.size() && state.gradient.lpNorm<Eigen::Infinity>()<=tolerance) {converged=true;stop="converged";break;}
        if(state.stopReason==Avogadro::Calc::OptimizerStopReason::Stalled||state.iterationsRun==0) {stop="stalled";break;}
        stop="iterationLimit";
      }
      for(size_t i=0;i<molecule.atomCount();++i) molecule.atom(i).setPosition3d({x[i*3],x[i*3+1],x[i*3+2]});
    }
    double energy=method.value(x);if(!std::isfinite(energy)) throw std::runtime_error("Non-finite energy");
    result["energy"]=energy;result["iterations"]=performed;result["converged"]=converged;result["stopReason"]=stop;
  } else if(operation!="parse"&&operation!="analyze"&&operation!="export") throw std::runtime_error("Unsupported chemistry operation: "+operation);
  check(token);
  std::string canonical;
  if(!formats.writeString(molecule,canonical,"cjson")) throw std::runtime_error("Cannot serialize chemical structure");
  result["cjson"]=canonical;result["formula"]=molecule.formula();result["mass"]=molecule.mass();
  result["atomCount"]=molecule.atomCount();result["bondCount"]=molecule.bondCount();result["residueCount"]=molecule.residueCount();
  result["coordinateSetCount"]=molecule.coordinate3dCount();
  if(!atomMaps.empty()) result["atomMaps"]=atomMaps;
  result["engine"]="Avogadro a5947518";
  if(operation=="export") {
    std::string text;auto output=options.at("outputFormat").get<std::string>();
    if(output=="qcschema") {
      Avogadro::QuantumIO::QCSchema writer;
      if(!writer.writeString(text,molecule)) throw std::runtime_error(writer.error());
    } else if(!formats.writeString(molecule,text,output)) throw std::runtime_error("Cannot export requested format");
    result["text"]=text;result["format"]=output;
  }
  return {{"ok",true},{"result",result}};
}
extern "C" {
void *fch_cancel_create(){try{return new Cancellation;}catch(...){return nullptr;}}
void fch_cancel_request(void *token){if(token)static_cast<Cancellation*>(token)->cancelled.store(true);}
void fch_cancel_destroy(void *token){delete static_cast<Cancellation*>(token);}
char *fch_execute(const char *request, void *rawToken){
  json response;
  try {
    if(!request||strnlen(request,16*1024*1024+1)>16*1024*1024) throw std::runtime_error("Request exceeds input limit");
    std::lock_guard<std::mutex> lock(nativeMutex);
    response=execute(json::parse(request,depthCheck),static_cast<Cancellation*>(rawToken));
  }catch(const std::exception &e){response={{"ok",false},{"error",e.what()},{"cancelled",rawToken&&static_cast<Cancellation*>(rawToken)->cancelled.load()}};}
  catch(...){response={{"ok",false},{"error","Native chemistry failed"}};}
  const auto text=response.dump();auto *output=static_cast<char*>(std::malloc(text.size()+1));
  if(output)std::memcpy(output,text.c_str(),text.size()+1);return output;
}
void fch_free(char *response){std::free(response);}
}
