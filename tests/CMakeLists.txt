if(NOT TARGET Qt::Test)
    find_package(Qt6 COMPONENTS Test REQUIRED)
endif()

qt_add_executable(bdsup2subplusplus_tests
    test_palette.cpp
)

target_include_directories(bdsup2subplusplus_tests PRIVATE
    "${BDSUP_SRC_ROOT}"
    "${BDSUP_SRC_ROOT}/Subtitles"
)

target_link_libraries(bdsup2subplusplus_tests PRIVATE
    Qt::Test
    bdsup2subplusplus_core
)

qt_add_executable(bdsup2subplusplus_palette_behavior_tests
    test_palette_behavior.cpp
)

target_include_directories(bdsup2subplusplus_palette_behavior_tests PRIVATE
    "${BDSUP_SRC_ROOT}"
    "${BDSUP_SRC_ROOT}/Subtitles"
)

target_link_libraries(bdsup2subplusplus_palette_behavior_tests PRIVATE
    Qt::Test
    bdsup2subplusplus_core
)

qt_add_executable(bdsup2subplusplus_hr_time_tests
    test_hr_time.cpp
)

target_include_directories(bdsup2subplusplus_hr_time_tests PRIVATE
    "${BDSUP_SRC_ROOT}"
    "${BDSUP_SRC_ROOT}/Tools"
)

target_link_libraries(bdsup2subplusplus_hr_time_tests PRIVATE
    Qt::Test
    bdsup2subplusplus_core
)

add_test(NAME PaletteTest COMMAND bdsup2subplusplus_tests)
add_test(NAME PaletteBehaviorTest COMMAND bdsup2subplusplus_palette_behavior_tests)
add_test(NAME HrTimeTest COMMAND bdsup2subplusplus_hr_time_tests)
