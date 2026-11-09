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

find_package(Threads REQUIRED)

find_package(PkgConfig REQUIRED)

pkg_check_modules(GLIB REQUIRED glib-2.0)
pkg_check_modules(LS2 REQUIRED luna-service2)

target_include_directories(webos-vnc PRIVATE
    ${GLIB_INCLUDE_DIRS}
    ${LS2_INCLUDE_DIRS}
)

target_link_directories(webos-vnc PRIVATE
    ${GLIB_LIBRARY_DIRS}
    ${LS2_LIBRARY_DIRS}
)

target_link_libraries(webos-vnc PRIVATE
    ${GLIB_LIBRARIES}
    ${LS2_LIBRARIES}
)

target_link_libraries(webos-vnc
    PRIVATE
    Threads::Threads
)

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
