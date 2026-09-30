cmake_minimum_required(VERSION 3.20)
project(mdview_render LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# The native Cairo adapter is maintained by litehtml but not installed by Arch's
# litehtml package. Build it from the matching v0.10 source snapshot.
set(LITEHTML_SOURCE_DIR "${CMAKE_SOURCE_DIR}/third_party/litehtml" CACHE PATH "litehtml v0.10 source tree")
if(NOT EXISTS "${LITEHTML_SOURCE_DIR}/containers/cairo/render2png.cpp")
    message(FATAL_ERROR "litehtml v0.10 is missing. Run ./scripts/build.sh to download it.")
endif()

find_package(PkgConfig REQUIRED)
pkg_check_modules(RENDER_LIBS REQUIRED IMPORTED_TARGET gdk-3.0 cairo pango pangocairo fontconfig)
find_library(LITEHTML_LIBRARY NAMES litehtml REQUIRED)
find_path(LITEHTML_INCLUDE_DIR NAMES litehtml.h PATH_SUFFIXES litehtml REQUIRED)
set(CAIRO_DIR "${LITEHTML_SOURCE_DIR}/containers/cairo")

add_executable(mdview-render
    src/main.cpp
    "${CAIRO_DIR}/cairo_borders.cpp"
    "${CAIRO_DIR}/container_cairo.cpp"
    "${CAIRO_DIR}/container_cairo_pango.cpp"
    "${CAIRO_DIR}/conic_gradient.cpp"
    "${CAIRO_DIR}/render2png.cpp"
)
target_include_directories(mdview-render PRIVATE
    "${CAIRO_DIR}"
    "${LITEHTML_SOURCE_DIR}/include"
    "${LITEHTML_INCLUDE_DIR}"
)
target_link_libraries(mdview-render PRIVATE PkgConfig::RENDER_LIBS "${LITEHTML_LIBRARY}")
target_compile_options(mdview-render PRIVATE -Wall -Wextra)

pkg_check_modules(CMARK REQUIRED IMPORTED_TARGET libcmark-gfm)
add_executable(mdview-preview
    src/preview.cpp
    "${CAIRO_DIR}/cairo_borders.cpp"
    "${CAIRO_DIR}/container_cairo.cpp"
    "${CAIRO_DIR}/container_cairo_pango.cpp"
    "${CAIRO_DIR}/conic_gradient.cpp"
)
target_include_directories(mdview-preview PRIVATE "${CAIRO_DIR}" "${LITEHTML_SOURCE_DIR}/include" "${LITEHTML_INCLUDE_DIR}")
target_link_libraries(mdview-preview PRIVATE PkgConfig::RENDER_LIBS PkgConfig::CMARK "${LITEHTML_LIBRARY}")
target_compile_options(mdview-preview PRIVATE -Wall -Wextra)
