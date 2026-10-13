get_filename_component(LIBMPV_PACKAGE_DIR "${CMAKE_CURRENT_LIST_DIR}" REALPATH)
set(LIBMPV_LOCAL_DIR "${LIBMPV_PACKAGE_DIR}/../../../build/local-libmpv")
if(EXISTS "${LIBMPV_LOCAL_DIR}/SHA256SUMS")
  include("${CMAKE_CURRENT_LIST_DIR}/libmpv-local.cmake")
  return()
endif()

message(FATAL_ERROR
  "Required temporary libmpv fix is missing: ${LIBMPV_LOCAL_DIR}/SHA256SUMS. "
  "See third_party/media_kit_libs_windows_video/LOCAL_LIBMPV.md (#18603 + #18604).")
