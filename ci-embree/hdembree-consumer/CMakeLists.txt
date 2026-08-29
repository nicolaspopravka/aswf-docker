cmake_minimum_required(VERSION 3.21)
project(hdembree-consumer LANGUAGES CXX)

# External consumer build of hdEmbree (hdCycles pattern).  Compiles the
# upstream hdEmbree plugin sources from a pinned OpenUSD checkout against
# the base image's prebuilt OpenUSD by DIRECT LINKAGE -- headers from
# ${USD_INCLUDE_DIR}, libraries from ${USD_LIB_DIR} -- then installs a
# self-contained delegate tree:
#
#   <prefix>/hydra/hdEmbree.so
#   <prefix>/hydra/plugInfo.json                          (Includes root)
#   <prefix>/hydra/hdEmbree/resources/plugInfo.json       (substituted)
#
# PXR_PLUGINPATH_NAME=<prefix>/hydra then registers the delegate.
#
# find_package(pxr) was abandoned deliberately: the conan-built pxrConfig
# on the ASWF images bakes dead conan-home paths for its find_dependency
# calls (Python3, MaterialX_DIR, Imath_DIR) and pxrTargets references
# CONAN_LIB::* target names that the shipped dependency configs do not
# define (GHA runs 33246312623 / 33248317478).  Direct linkage against the
# installed libraries is the same consumer pattern the proven hdCycles
# builds use.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(HDEMBREE_SOURCE_DIR "" CACHE PATH
    "Directory of the upstream hdEmbree plugin sources inside an OpenUSD checkout")
set(EMBREE_ROOT "/opt/embree" CACHE PATH "Embree install prefix")
set(USD_INCLUDE_DIR "/usr/local/include" CACHE PATH "Prebuilt OpenUSD headers")
set(USD_LIB_DIR "/usr/local/lib" CACHE PATH "Prebuilt OpenUSD libraries")

if(NOT HDEMBREE_SOURCE_DIR)
  message(FATAL_ERROR "HDEMBREE_SOURCE_DIR is required")
endif()

find_library(EMBREE_LIBRARY
  NAMES embree3
  PATHS "${EMBREE_ROOT}/lib"
  NO_DEFAULT_PATH
  REQUIRED)
message(STATUS "Embree library: ${EMBREE_LIBRARY}")

# Locate the pxr libraries hdEmbree links, tolerating per-year layouts:
# conan ASWF builds install split libusd_<name>.so; other builds may use
# lib<name>.so or the monolithic libusd_ms.so.
set(HDEMBREE_PXR_LIBS plug tf vt gf work hf hd hdx)
set(_split_paths "")
set(_missing "")
foreach(_name IN LISTS HDEMBREE_PXR_LIBS)
  find_library(_pxr_lib
    NAMES "usd_${_name}" "${_name}"
    PATHS "${USD_LIB_DIR}"
    NO_DEFAULT_PATH)
  if(_pxr_lib)
    list(APPEND _split_paths "${_pxr_lib}")
  else()
    list(APPEND _missing "${_name}")
  endif()
  unset(_pxr_lib CACHE)
endforeach()

if(_missing)
  find_library(_pxr_ms
    NAMES usd_ms
    PATHS "${USD_LIB_DIR}"
    NO_DEFAULT_PATH)
  if(NOT _pxr_ms)
    message(FATAL_ERROR
      "Cannot locate prebuilt OpenUSD libraries (missing: ${_missing}; "
      "no monolithic libusd_ms.so in ${USD_LIB_DIR})")
  endif()
  set(HDEMBREE_LINK_LIBRARIES "${_pxr_ms}")
  message(STATUS "OpenUSD monolithic library: ${_pxr_ms} (split libs missing: ${_missing})")
else()
  set(HDEMBREE_LINK_LIBRARIES "${_split_paths}")
  message(STATUS "OpenUSD split libraries:")
  foreach(_p IN LISTS _split_paths)
    message(STATUS "  ${_p}")
  endforeach()
endif()

find_library(HDEMBREE_TBB_LIBRARY
  NAMES tbb
  PATHS "${USD_LIB_DIR}" /usr/local/lib)
message(STATUS "TBB library: ${HDEMBREE_TBB_LIBRARY}")

# hdEmbree pulls in pxr/external/boost/python (wrap_python.hpp), which
# includes pyconfig.h: add the image Python's include dir (the same conan
# cpython the installed pxr was built against).
set(IMAGE_PYTHON_EXECUTABLE "/usr/local/bin/python3")
execute_process(
  COMMAND "${IMAGE_PYTHON_EXECUTABLE}" -c
    "import sysconfig; print(sysconfig.get_config_var('INCLUDEPY'))"
  RESULT_VARIABLE _pyinc_rc
  OUTPUT_VARIABLE _pyinc
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_QUIET)
if(NOT _pyinc_rc EQUAL 0 OR NOT _pyinc OR NOT EXISTS "${_pyinc}")
  file(GLOB _pyinc "${USD_INCLUDE_DIR}/python3*")
  list(LENGTH _pyinc _pyinc_len)
  if(NOT _pyinc_len EQUAL 1)
    message(FATAL_ERROR
      "Cannot locate the Python include dir (pyconfig.h) for wrap_python.hpp")
  endif()
  list(GET _pyinc 0 _pyinc)
endif()
set(PYTHON_INCLUDE_DIR "${_pyinc}")
message(STATUS "Python include dir: ${PYTHON_INCLUDE_DIR}")

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
# installed headers and the image's TBB headers resolve from
# ${USD_INCLUDE_DIR}.
target_include_directories(hdEmbree PRIVATE
  "${USD_INCLUDE_DIR}"
  "${PYTHON_INCLUDE_DIR}"
  "${HDEMBREE_SOURCE_DIR}/../../../.."
  "${EMBREE_ROOT}/include")

target_link_libraries(hdEmbree PRIVATE
  ${HDEMBREE_LINK_LIBRARIES}
  ${HDEMBREE_TBB_LIBRARY}
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
