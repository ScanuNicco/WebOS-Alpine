cmake_minimum_required(VERSION 3.16)
project(webos_vnc LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_path(SDL2_INCLUDE_DIR
    NAMES SDL.h
    PATH_SUFFIXES SDL2
    REQUIRED
)

find_library(SDL2_LIBRARY
    NAMES SDL2
    REQUIRED
)

add_executable(webos-vnc src/main.cpp)

target_include_directories(webos-vnc PRIVATE
    ${SDL2_INCLUDE_DIR}
)

target_link_libraries(webos-vnc PRIVATE
    ${SDL2_LIBRARY}
)

# Avoid requiring a separately installed C++ runtime on the TV.
target_link_options(webos-vnc PRIVATE
    -static-libstdc++
    -static-libgcc
)
