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
# Python paths into find_dependency(Python3 <ver> EXACT) guarded by
# "if (NOT DEFINED ...)" -- but those baked paths do not exist in the
# shipped image.  The same conan cpython IS installed at /usr/local, so
# query it and pin ALL the Python3_* cache variables pxrConfig consults
# (empirically FindPython does not define Python3_LIBRARY itself, so the
# variables are set explicitly rather than via find_package(Python3)).
set(IMAGE_PYTHON_EXECUTABLE "/usr/local/bin/python3")
execute_process(
  COMMAND "${IMAGE_PYTHON_EXECUTABLE}" -c
    "import sysconfig, sys; print(sysconfig.get_config_var('LIBDIR')); print(sysconfig.get_config_var('INCLUDEPY')); print(sysconfig.get_config_var('LDLIBRARY')); print('%d.%d.%d' % sys.version_info[:3])"
  RESULT_VARIABLE _pyconfig_rc
  OUTPUT_VARIABLE _pyconfig_out
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_QUIET)
if(NOT _pyconfig_rc EQUAL 0 OR NOT _pyconfig_out)
  message(FATAL_ERROR "Cannot query Python sysconfig via ${IMAGE_PYTHON_EXECUTABLE}")
endif()
string(REPLACE "\n" ";" _pyconfig "${_pyconfig_out}")
list(LENGTH _pyconfig _pyconfig_len)
if(NOT _pyconfig_len EQUAL 4)
  message(FATAL_ERROR "Unexpected sysconfig output: ${_pyconfig}")
endif()
list(GET _pyconfig 0 _py_libdir)
list(GET _pyconfig 1 _py_includepy)
list(GET _pyconfig 2 _py_ldlibrary)
list(GET _pyconfig 3 _py_version)
set(_py_library "${_py_libdir}/${_py_ldlibrary}")
if(_py_ldlibrary STREQUAL "" OR NOT EXISTS "${_py_library}")
  file(GLOB _py_library "${_py_libdir}/libpython${_py_version}*.so")
  list(LENGTH _py_library _py_library_len)
  if(NOT _py_library_len EQUAL 1)
    message(FATAL_ERROR "Cannot locate libpython under ${_py_libdir} (LDLIBRARY='${_py_ldlibrary}')")
  endif()
  list(GET _py_library 0 _py_library)
endif()
message(STATUS "Image Python ${_py_version}: ${IMAGE_PYTHON_EXECUTABLE}")
message(STATUS "Image Python library: ${_py_library}")
message(STATUS "Image Python include: ${_py_includepy}")
set(Python3_EXECUTABLE "${IMAGE_PYTHON_EXECUTABLE}" CACHE FILEPATH "" FORCE)
set(Python3_LIBRARY "${_py_library}" CACHE FILEPATH "" FORCE)
set(Python3_INCLUDE_DIR "${_py_includepy}" CACHE PATH "" FORCE)
set(Python3_VERSION "${_py_version}" CACHE STRING "" FORCE)
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
