#include "FloeMoleculePreviewBridge.h"
#include <GraphMol/SmilesParse/SmilesParse.h>
#include <GraphMol/SmilesParse/SmilesWrite.h>
#include <GraphMol/FileParsers/FileParsers.h>
#include <GraphMol/MolOps.h>
#include <GraphMol/DistGeomHelpers/Embedder.h>
#include <GraphMol/ForceFieldHelpers/MMFF/MMFF.h>
#include <GraphMol/ForceFieldHelpers/UFF/UFF.h>
#include <GraphMol/Conformer.h>
#include <RDGeneral/versions.h>
#include <nlohmann/json.hpp>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <map>
#include <sstream>

using json = nlohmann::json;
using Clock = std::chrono::steady_clock;
struct Cancellation { std::atomic<bool> cancelled{false}; std::atomic<int> stage{0}; };
struct Failure : std::runtime_error {
  std::string code;
  Failure(std::string c, std::string message) : std::runtime_error(message), code(std::move(c)) {}
};
struct Invocation {
  Cancellation *token;
  Clock::time_point deadline;
  void check() const {
    if (token && token->cancelled.load()) throw Failure("cancelled", "Preview generation cancelled.");
    if (Clock::now() >= deadline) throw Failure("timeout", "Preview generation exceeded its time budget.");
  }
  void stage(int value) const { check(); if (token) token->stage.store(value); }
};
static std::timed_mutex engineMutex;
static thread_local Invocation *activeInvocation = nullptr;
static void progress(unsigned int) { if (activeInvocation) activeInvocation->check(); }
static void preflight(const std::string &source, const std::string &format) {
  // Reject excessive graph sizes before a third-party parser allocates atoms.
  if (format=="smiles") {
    unsigned int count=0;
    for (size_t i=0;i<source.size();++i) {
      const auto c=source[i];
      if(c=='[') {
        const auto end=source.find(']',i+1);
        if(end==std::string::npos) throw Failure("invalidMolecule","Unclosed atom specification.");
        i=end; ++count;
      } else if((c>='A' && c<='Z') || std::strchr("bcnops*",c)) {
        ++count;
        if(c>='A' && c<='Z' && i+1<source.size() && source[i+1]>='a' && source[i+1]<='z') ++i;
      }
      if(count>128) throw Failure("atomLimit","This preview prototype accepts up to 128 input atoms.");
    }
  } else if(format=="mol") {
    std::istringstream lines(source); std::string line;
    while(std::getline(lines,line)) {
      int atoms=0;
      if(line.find("V2000")!=std::string::npos) {
        std::istringstream count(line.substr(0,3)); count>>atoms;
      } else if(auto pos=line.find("V30 COUNTS ");pos!=std::string::npos) {
        std::istringstream count(line.substr(pos+11));
        if(!(count>>atoms)) throw Failure("invalidMolecule","Invalid molecule counts.");
      }
      if(atoms>128) throw Failure("atomLimit","This preview prototype accepts up to 128 input atoms.");
    }
  }
}
static int integer(const json &j, const char *key, int fallback, int low, int high) {
  if (!j.contains(key)) return fallback;
  if (!j[key].is_number_integer()) throw Failure("invalidOptions", std::string(key)+" must be an integer.");
  auto n = j[key].get<int64_t>();
  if (n < low || n > high) throw Failure("invalidOptions", std::string(key)+" is outside the preview budget.");
  return static_cast<int>(n);
}
static json generate(const json &request, Cancellation *token) {
  if (!request.is_object() || request.size() > 3 || !request.contains("input") || !request.contains("format"))
    throw Failure("invalidInput", "Expected input, format and optional options.");
  for (auto it=request.begin(); it!=request.end(); ++it)
    if (it.key()!="input" && it.key()!="format" && it.key()!="options") throw Failure("invalidInput", "Unknown request field.");
  if (!request["input"].is_string() || !request["format"].is_string()) throw Failure("invalidInput", "Input and format must be strings.");
  const auto source=request["input"].get<std::string>(), format=request["format"].get<std::string>();
  if (source.empty() || source.size()>256*1024 || source.find('\0')!=std::string::npos)
    throw Failure("invalidInput", "Empty or oversized molecule input.");
  const auto options=request.value("options",json::object());
  if (!options.is_object()) throw Failure("invalidOptions", "Options must be an object.");
  for (auto it=options.begin(); it!=options.end(); ++it)
    if (it.key()!="seed" && it.key()!="timeoutMilliseconds" && it.key()!="maxIterations" && it.key()!="forceField")
      throw Failure("invalidOptions", "Unknown preview option.");
  int seed=integer(options,"seed",42,0,2147483647);
  int milliseconds=integer(options,"timeoutMilliseconds",3000,1,10000);
  int iterations=integer(options,"maxIterations",100,0,500);
  const auto field=options.value("forceField",std::string("MMFF94"));
  if (field!="MMFF94" && field!="UFF" && field!="none") throw Failure("invalidOptions", "Choose MMFF94, UFF or none explicitly.");
  auto started=Clock::now();
  Invocation invocation{token,started+std::chrono::milliseconds(milliseconds)};
  std::unique_lock<std::timed_mutex> lock(engineMutex,std::defer_lock);
  while (!lock.try_lock_for(std::chrono::milliseconds(5))) invocation.check();
  struct Scope { Scope(Invocation *i){activeInvocation=i;} ~Scope(){activeInvocation=nullptr;} } scope(&invocation);
  invocation.stage(1);
  preflight(source,format);
  std::unique_ptr<RDKit::RWMol> molecule;
  if (format=="smiles") molecule.reset(RDKit::SmilesToMol(source));
  else if (format=="mol") molecule.reset(RDKit::MolBlockToMol(source,true,false,true));
  else throw Failure("unsupportedFormat", "Choose MOL or SMILES for the molecule graph.");
  if (!molecule || molecule->getNumAtoms()==0) throw Failure("invalidMolecule", "The molecule could not be read.");
  const auto originalCount=molecule->getNumAtoms();
  if (originalCount>128) throw Failure("atomLimit", "This preview prototype accepts up to 128 input atoms.");
  for (const auto atom:molecule->atoms())
    if (atom->getAtomicNum()==0 || atom->hasQuery()) throw Failure("unsupportedMolecule", "Query atoms need a complete molecule before preview.");
  if (RDKit::MolOps::getMolFrags(*molecule).size()!=1)
    throw Failure("multipleFragments", "Preview one connected molecule at a time.");
  RDKit::MolOps::assignStereochemistry(*molecule,true,true);
  const auto originalSmiles=RDKit::MolToSmiles(*molecule,true);
  std::map<unsigned int,std::string> expectedStereo;
  std::map<unsigned int,RDKit::Bond::BondStereo> expectedBondStereo;
  for (const auto atom:molecule->atoms()) {
    std::string cip;
    if (atom->getPropIfPresent("_CIPCode",cip)) expectedStereo[atom->getIdx()]=cip;
  }
  for(const auto bond:molecule->bonds())
    if(bond->getStereo()==RDKit::Bond::STEREOE || bond->getStereo()==RDKit::Bond::STEREOZ)
      expectedBondStereo[bond->getIdx()]=bond->getStereo();
  RDKit::MolOps::addHs(*molecule);
  if (molecule->getNumAtoms()>384) throw Failure("atomLimit", "Explicit hydrogens exceed the preview atom budget.");
  invocation.stage(2);
  auto parameters=RDKit::DGeomHelpers::ETKDGv3;
  parameters.randomSeed=seed; parameters.numThreads=1; parameters.maxIterations=30;
  parameters.timeout=std::max(1,(milliseconds+999)/1000);
  parameters.enforceChirality=true; parameters.trackFailures=true; parameters.callback=&progress;
  const int conformer=RDKit::DGeomHelpers::EmbedMolecule(*molecule,parameters);
  invocation.check();
  if (conformer<0) throw Failure("embeddingFailed", "No valid three-dimensional conformer was generated.");
  const auto embedded=Clock::now();
  invocation.stage(3);
  std::string optimization="skipped";
  json energy=nullptr;
  int chunks=0;
  std::unique_ptr<ForceFields::ForceField> forceField;
  if (field!="none" && iterations>0) {
    if (field=="MMFF94") {
      RDKit::MMFF::MMFFMolProperties properties(*molecule,"MMFF94");
      if (properties.isValid()) forceField.reset(RDKit::MMFF::constructForceField(*molecule,&properties,10.0,conformer,true));
    } else forceField.reset(RDKit::UFF::constructForceField(*molecule,10.0,conformer,true));
    if (!forceField) optimization="parametersUnavailable";
    else {
      forceField->initialize(); optimization="iterationLimit";
      for (int n=0; n<iterations; n+=5) {
        invocation.check();
        const auto count=std::min(5,iterations-n);
        int status=forceField->minimize(count,1e-4,1e-6); chunks+=count;
        if (status==0) {optimization="converged"; break;}
      }
      const auto e=forceField->calcEnergy();
      if (!std::isfinite(e)) throw Failure("invalidGeometry", "Optimization returned non-finite energy.");
      energy=e;
    }
  }
  invocation.check();
  // Compare specified stereocentres against the actual generated coordinates.
  RDKit::RWMol from3D(*molecule);
  RDKit::MolOps::assignStereochemistryFrom3D(from3D,conformer,true);
  RDKit::MolOps::assignStereochemistry(from3D,true,true);
  for (const auto &[index,expected]:expectedStereo) {
    std::string observed;
    if (!from3D.getAtomWithIdx(index)->getPropIfPresent("_CIPCode",observed) || observed!=expected)
      throw Failure("stereoMismatch", "Generated coordinates did not preserve specified stereochemistry.");
  }
  for(const auto &[index,expected]:expectedBondStereo)
    if(from3D.getBondWithIdx(index)->getStereo()!=expected)
      throw Failure("stereoMismatch","Generated coordinates did not preserve double-bond stereochemistry.");
  json numbers=json::array(),charges=json::array(),isotopes=json::array(),coords=json::array(),mapping=json::array();
  const auto &conf=molecule->getConformer(conformer);
  for (const auto atom:molecule->atoms()) {
    const auto &p=conf.getAtomPos(atom->getIdx());
    if (!std::isfinite(p.x)||!std::isfinite(p.y)||!std::isfinite(p.z)||std::max({std::abs(p.x),std::abs(p.y),std::abs(p.z)})>1e5)
      throw Failure("invalidGeometry", "Generated coordinates are outside the finite preview range.");
    numbers.push_back(atom->getAtomicNum()); charges.push_back(atom->getFormalCharge()); isotopes.push_back(atom->getIsotope());
    coords.push_back(p.x); coords.push_back(p.y); coords.push_back(p.z);
  }
  for (unsigned int i=0;i<originalCount;++i) mapping.push_back(i);
  RDKit::RWMol kekule(*molecule); RDKit::MolOps::Kekulize(kekule);
  json connections=json::array(),orders=json::array();
  for (const auto bond:kekule.bonds()) {connections.push_back(bond->getBeginAtomIdx());connections.push_back(bond->getEndAtomIdx());orders.push_back(bond->getBondTypeAsDouble());}
  json cjson={{"chemicalJson",1},{"atoms",{{"elements",{{"number",numbers}}},{"formalCharges",charges},{"isotopes",isotopes},{"coords",{{"3d",coords}}}}},
              {"bonds",{{"connections",{{"index",connections}}},{"order",orders}}}};
  auto molblock=RDKit::MolToMolBlock(*molecule,true,conformer,true);
  invocation.check();
  return {{"cjson",cjson.dump()},{"molblock",molblock},{"canonicalSmiles",originalSmiles},
          {"inputAtomCount",originalCount},{"atomCount",molecule->getNumAtoms()},{"bondCount",molecule->getNumBonds()},
          {"inputAtomToOutput",mapping},{"specifiedStereoCenters",expectedStereo.size()},{"specifiedStereoPreserved",true},
          {"engine",std::string("RDKit ")+RDKit::rdkitVersion},{"method","ETKDGv3"},{"seed",seed},
          {"forceField",field},{"optimizationStatus",optimization},{"optimizationIterationBudgetUsed",chunks},{"energy",energy},{"energyUnits","kcal/mol"},
          {"embeddingMilliseconds",std::chrono::duration<double,std::milli>(embedded-started).count()},
          {"totalMilliseconds",std::chrono::duration<double,std::milli>(Clock::now()-started).count()}};
}
extern "C" void *fmp_cancel_create(){return new(std::nothrow) Cancellation;}
extern "C" void fmp_cancel_request(void *p){if(p) static_cast<Cancellation*>(p)->cancelled.store(true);}
extern "C" void fmp_cancel_destroy(void *p){delete static_cast<Cancellation*>(p);}
extern "C" int fmp_stage(void *p){return p?static_cast<Cancellation*>(p)->stage.load():-1;}
extern "C" void fmp_free(char *p){std::free(p);}
extern "C" char *fmp_generate(const char *request,void *opaque){
  auto *token=static_cast<Cancellation*>(opaque);
  json envelope;
  try {
    if(token && token->cancelled.load()) throw Failure("cancelled","Preview generation cancelled.");
    if(!request || strnlen(request,512*1024+1)>512*1024) throw Failure("invalidInput","Request exceeds the preview size limit.");
    auto depth=[](int d,json::parse_event_t,json&){if(d>16)throw Failure("invalidInput","Request nesting exceeds the preview limit.");return true;};
    envelope={{"ok",true},{"result",generate(json::parse(request,depth),token)}};
  }catch(const Failure &e){envelope={{"ok",false},{"code",e.code},{"error",e.what()}};}
   catch(const std::exception &e){envelope={{"ok",false},{"code","invalidMolecule"},{"error",std::string(e.what()).substr(0,1024)}};}
   catch(...){envelope={{"ok",false},{"code","nativeFailure"},{"error","Native preview generation failed."}};}
  if(token) token->stage.store(4);
  const auto output=envelope.dump();
  if(output.size()>4*1024*1024) return nullptr;
  auto *copy=static_cast<char*>(std::malloc(output.size()+1));
  if(copy) std::memcpy(copy,output.c_str(),output.size()+1);
  return copy;
}
