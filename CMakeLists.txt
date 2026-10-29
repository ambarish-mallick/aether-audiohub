# Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.20)
project(Aether VERSION 1.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

option(AETHER_SANITIZE "Build with address and undefined-behaviour sanitizers" OFF)

add_library(aether_core STATIC
  core/src/engine.cpp
  core/src/design.cpp)
target_include_directories(aether_core PUBLIC core/include PRIVATE core/src)
target_compile_options(aether_core PRIVATE -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wno-sign-conversion)
if(AETHER_SANITIZE)
  target_compile_options(aether_core PUBLIC -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_link_options(aether_core PUBLIC -fsanitize=address,undefined)
endif()

add_executable(aether_tests core/tests/test_core.cpp)
target_include_directories(aether_tests PRIVATE core/src)
target_link_libraries(aether_tests PRIVATE aether_core)

add_executable(aether-render tools/aether-render/main.cpp)
target_link_libraries(aether-render PRIVATE aether_core)

add_executable(aether-bench benchmarks/bench_core.cpp)
target_link_libraries(aether-bench PRIVATE aether_core)

enable_testing()
add_test(NAME core COMMAND aether_tests)
