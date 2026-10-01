cmake_minimum_required(VERSION 3.16)
project(upstream_entry NONE)
# M5 relay1: parity merge - localpty + rdpproxy native modules.
# .so files are pre-built (extracted from parity HAP, x86_64/arm64-v8a)
# and placed in entry/libs/<abi>/. CMake does not recompile them.
# WSL cross-compile chain can regenerate these later if needed.
message(STATUS "upstream entry: M5 parity merge - pre-built libs in libs/<abi>/")
