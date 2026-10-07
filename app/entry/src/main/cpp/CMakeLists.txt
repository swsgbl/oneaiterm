cmake_minimum_required(VERSION 3.16)
project(upstream_entry NONE)
# M5 relay1: parity merge - localpty + rdpproxy native modules.
# .so files are pre-built and placed in entry/libs/<abi>/; CMake does NOT
# recompile them. After ANY localpty.cpp change run
#   bash entry/src/main/cpp/build-localpty.sh all   (from WSL)
# to rebuild BOTH ABIs, or the fix dies in source (rot incident 2026-10-07:
# the r6f PATH/HOME fix never reached the shipped 09-28 prebuilt and every
# installed app ran a PATH-less PTY).
message(STATUS "upstream entry: M5 parity merge - pre-built libs in libs/<abi>/")
