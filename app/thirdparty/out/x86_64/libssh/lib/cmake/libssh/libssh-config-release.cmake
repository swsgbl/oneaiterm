#----------------------------------------------------------------
# Generated CMake target import file for configuration "Release".
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "ssh" for configuration "Release"
set_property(TARGET ssh APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(ssh PROPERTIES
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libssh.so.4.10.1"
  IMPORTED_SONAME_RELEASE "libssh.so.4"
  )

list(APPEND _cmake_import_check_targets ssh )
list(APPEND _cmake_import_check_files_for_ssh "${_IMPORT_PREFIX}/lib/libssh.so.4.10.1" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
