cmake_minimum_required(VERSION 3.21)
project(hdembree-consumer LANGUAGES CXX)

# External pxr consumer build of hdEmbree (hdCycles pattern).  Compiles the
# upstream hdEmbree plugin sources from a pinned OpenUSD checkout against
# the base image's prebuilt OpenUSD via its pxrConfig, then installs a
# self-contained delegate tree:
#
#   <prefix>/hydra/hdEmbree.so
#   <prefix>/hydra/plugInfo.json                          (Includes root)
#   <prefix>/hydra/hdEmbree/resources/plugInfo.json       (substituted)
#
# PXR_PLUGINPATH_NAME=<prefix>/hydra then registers the delegate.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(HDEMBREE_SOURCE_DIR "" CACHE PATH
    "Directory of the upstream hdEmbree plugin sources inside an OpenUSD checkout")
set(EMBREE_ROOT "/opt/embree" CACHE PATH "Embree install prefix")

if(NOT HDEMBREE_SOURCE_DIR)
  message(FATAL_ERROR "HDEMBREE_SOURCE_DIR is required")
endif()

# The conan-built pxrConfig on the ASWF images bakes its build machine's
# Python paths into find_dependency(Python3 <ver> EXACT); the same conan
# cpython is installed at /usr/local in the shipped image, so resolve it
# first.  pxrConfig only fills Python3_* cache variables when NOT DEFINED,
# which makes this the sanctioned override path (no config edits).
set(Python3_EXECUTABLE "/usr/local/bin/python3" CACHE FILEPATH
    "Image Python -- the same conan cpython this pxrConfig was built against" FORCE)
find_package(Python3 COMPONENTS Interpreter Development REQUIRED)
find_package(pxr CONFIG REQUIRED)

find_library(EMBREE_LIBRARY
  NAMES embree3
  PATHS "${EMBREE_ROOT}/lib"
  NO_DEFAULT_PATH
  REQUIRED)
message(STATUS "Embree library: ${EMBREE_LIBRARY}")

# TBB comes from the base image; pxr's exported targets normally carry it
# transitively, but link it explicitly when the config is available so the
# TBB soname stays the single one pxr uses.
find_package(TBB CONFIG QUIET)
if(TBB_FOUND)
  set(HDEMBREE_TBB_TARGET TBB::tbb)
endif()

# Glob the upstream sources so the consumer follows per-year source lists
# (e.g. implicitSurfaceSceneIndexPlugin.cpp does not exist in older years).
file(GLOB HDEMBREE_SOURCES CONFIGURE_DEPENDS "${HDEMBREE_SOURCE_DIR}/*.cpp")
list(LENGTH HDEMBREE_SOURCES HDEMBREE_SOURCE_COUNT)
if(HDEMBREE_SOURCE_COUNT EQUAL 0)
  message(FATAL_ERROR "No hdEmbree sources under ${HDEMBREE_SOURCE_DIR}")
endif()
message(STATUS "hdEmbree sources: ${HDEMBREE_SOURCE_COUNT}")

add_library(hdEmbree SHARED ${HDEMBREE_SOURCES})

# Sources include their own headers as "pxr/imaging/plugin/hdEmbree/..." so
# the OpenUSD checkout root is the include root for the plugin; pxr's own
# installed headers resolve through the imported targets.
target_include_directories(hdEmbree PRIVATE
  "${HDEMBREE_SOURCE_DIR}/../../../.."
  "${EMBREE_ROOT}/include")

target_link_libraries(hdEmbree PRIVATE
  plug
  tf
  vt
  gf
  work
  hf
  hd
  hdx
  ${HDEMBREE_TBB_TARGET}
  ${EMBREE_LIBRARY})

target_compile_definitions(hdEmbree PRIVATE
  MFB_PACKAGE_NAME=hdEmbree
  MFB_ALT_PACKAGE_NAME=hdEmbree
  MFB_PACKAGE_MODULE=HdEmbree
  PXR_BUILD_LOCATION=usd
  PXR_PLUGIN_BUILD_LOCATION=../plugin/usd)

# plugInfo.json substitution with the exact values pxr's own macros use
# (OpenUSD cmake/macros/Private.cmake _plugInfo_subst: Root "..", resource
# dir name "resources"; the library path is the relative path from the
# plugin's resources dir to the installed library -- the same layout the
# proven hdCycles install uses).
set(PLUG_INFO_ROOT "..")
set(PLUG_INFO_LIBRARY_PATH "../hdEmbree.so")
set(PLUG_INFO_RESOURCE_PATH "resources")
set(PLUG_INFO_PLUGIN_NAME "pxr.hdEmbree")
configure_file("${HDEMBREE_SOURCE_DIR}/plugInfo.json"
               "${CMAKE_CURRENT_BINARY_DIR}/plugInfo.json" @ONLY)

install(TARGETS hdEmbree
  LIBRARY DESTINATION hydra)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/plugInfo.json"
  DESTINATION hydra/hdEmbree/resources)
install(FILES "${CMAKE_CURRENT_LIST_DIR}/plugInfo-root.json"
  RENAME plugInfo.json
  DESTINATION hydra)
