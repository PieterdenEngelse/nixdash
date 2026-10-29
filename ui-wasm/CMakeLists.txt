cmake_minimum_required(VERSION 3.24)
project(nixdash_ui_wasm)

# --- WebAssembly target (see ~/docs/qt.md Part 3) ---
set(Rust_CARGO_TARGET wasm32-unknown-emscripten)
set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

set(CMAKE_AUTOMOC ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# No QmlImportScanner component on wasm.
find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2)

find_package(CxxQt QUIET)
if(NOT CxxQt_FOUND)
    include(FetchContent)
    FetchContent_Declare(
        CxxQt
        GIT_REPOSITORY https://github.com/kdab/cxx-qt-cmake.git
        GIT_TAG main
    )
    FetchContent_MakeAvailable(CxxQt)
endif()

# Without an explicit QMAKE, cxx_qt_import_crate reads Qt::qmake
# IMPORTED_LOCATION - the HOST qmake in a cross build - and compiles the Rust
# side against x86 Qt headers (__builtin_ia32_pause undeclared). It also
# overrides any QMAKE exported in the shell, so it must be passed here.
if(NOT DEFINED CXXQT_QMAKE)
    if(DEFINED ENV{CXXQT_QMAKE})
        set(CXXQT_QMAKE $ENV{CXXQT_QMAKE})
    else()
        message(FATAL_ERROR
            "CXXQT_QMAKE is unset. Enter the wasm dev shell:  nix develop ./ui-wasm")
    endif()
endif()

cxx_qt_import_crate(
    MANIFEST_PATH rust/Cargo.toml
    CRATES nixdash_ui_wasm
    QMAKE ${CXXQT_QMAKE}
    # Must match build.rs .qt_module() calls exactly - cxx-qt-build checks and
    # fails with "Qt module mismatch between cxx-qt-build and CMake!"
    QT_MODULES Qt::Core Qt::Gui Qt::Qml Qt::Quick Qt::QuickControls2
)

cxx_qt_import_qml_module(nixdash_ui_wasm_qml_module
    URI "nixdash"
    SOURCE_CRATE nixdash_ui_wasm)

# qt_add_executable, not add_executable: only this emits the .html shell.
qt_add_executable(nixdash_ui_wasm_app cpp/main.cpp)
target_link_libraries(nixdash_ui_wasm_app PRIVATE nixdash_ui_wasm_qml_module)

# Static Qt needs plugins imported explicitly.
qt_import_qml_plugins(nixdash_ui_wasm_app)
