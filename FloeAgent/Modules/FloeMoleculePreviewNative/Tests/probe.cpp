#include "FloeMoleculePreviewBridge.h"
#include <iostream>
#include <string>
#include <thread>
#include <chrono>
int main(int argc,char **argv){
  std::string request;std::getline(std::cin,request,'\0');
  void *token=fmp_cancel_create();
  if(argc>1 && std::string(argv[1])=="--cancel")fmp_cancel_request(token);
  std::thread canceller;
  if(argc>1 && std::string(argv[1])=="--cancel-embedding")canceller=std::thread([&]{
    while(fmp_stage(token)<2)std::this_thread::sleep_for(std::chrono::microseconds(50));
    if(fmp_stage(token)==2)fmp_cancel_request(token);
  });
  char *result=fmp_generate(request.c_str(),token);
  if(canceller.joinable())canceller.join();
  if(!result){fmp_cancel_destroy(token);return 2;}
  std::cout<<result<<std::endl;fmp_free(result);fmp_cancel_destroy(token);return 0;
}
