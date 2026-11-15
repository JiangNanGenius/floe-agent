# Included after the pinned upstream project defines its dependency graph.
add_library(FloeMoleculePreviewBridge STATIC "${FLOE_PREVIEW_SOURCE_DIR}/Native/bridge.cpp")
target_include_directories(FloeMoleculePreviewBridge PUBLIC "${FLOE_PREVIEW_SOURCE_DIR}/Native/include"
  PRIVATE "${FLOE_JSON_INCLUDE_DIR}")
target_link_libraries(FloeMoleculePreviewBridge PUBLIC DistGeomHelpers FileParsers SmilesParse ForceFieldHelpers)
target_compile_options(FloeMoleculePreviewBridge PRIVATE -Wall -Wextra)
if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
  add_executable(MoleculePreviewProbe "${FLOE_PREVIEW_SOURCE_DIR}/Tests/probe.cpp")
  target_link_libraries(MoleculePreviewProbe PRIVATE FloeMoleculePreviewBridge)
endif()
