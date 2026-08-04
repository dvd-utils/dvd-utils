cmake_minimum_required(VERSION 3.16)
project(bdsup2subplusplus LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

cmake_minimum_required(VERSION 3.16)
project(bdsup2subplusplus LANGUAGES CXX)

# Ensure Qt6 is found so helper commands like qt_add_library are available
find_package(Qt6 COMPONENTS Core Gui Widgets Xml REQUIRED)

set(BDSUP_SRC_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/src")

if(NOT EXISTS "${BDSUP_SRC_ROOT}/Subtitles/supbd.cpp")
    message(FATAL_ERROR "未找到 BDSup2Sub++ 源码目录 src/Subtitles（仓库不完整）")
endif()

find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Xml Test)
qt_standard_project_setup()

file(GLOB BDSUP_FILTERS CONFIGURE_DEPENDS "${BDSUP_SRC_ROOT}/Filters/*.cpp")
file(GLOB BDSUP_SUBTITLES CONFIGURE_DEPENDS "${BDSUP_SRC_ROOT}/Subtitles/*.cpp")
file(GLOB BDSUP_TOOLS CONFIGURE_DEPENDS "${BDSUP_SRC_ROOT}/Tools/*.cpp")

qt_add_library(bdsup2subplusplus_core STATIC
    ${BDSUP_FILTERS}
    ${BDSUP_SUBTITLES}
    ${BDSUP_TOOLS}
)

target_include_directories(bdsup2subplusplus_core PUBLIC
    "${BDSUP_SRC_ROOT}"
    "${BDSUP_SRC_ROOT}/Subtitles"
    "${BDSUP_SRC_ROOT}/Filters"
    "${BDSUP_SRC_ROOT}/Tools"
)

target_link_libraries(bdsup2subplusplus_core PUBLIC
    Qt::Core
    Qt::Gui
    Qt::Widgets
    Qt::Xml
)

include(CTest)
if(BUILD_TESTING)
    add_subdirectory(tests)
endif()
