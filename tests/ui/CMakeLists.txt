# SPDX-License-Identifier: GPL-3.0-or-later

# UI tests: the real Main.qml and C++ types against a fake docker (bin/docker), offscreen and on a private D-Bus
# session, so they neither show a window nor reach the tray, the notifications or the Docker daemon of this machine.
find_package(Qt6 REQUIRED COMPONENTS QuickTest)
find_program(HAFEN_DBUS_RUN_SESSION dbus-run-session REQUIRED)
find_program(HAFEN_NODE node REQUIRED)

qt_add_executable(hafen_uitest main.cpp fixture.h fixture.cpp)
target_compile_definitions(hafen_uitest PRIVATE
    QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
    HAFEN_TEST_BIN_DIR="${CMAKE_CURRENT_SOURCE_DIR}/bin"
    HAFEN_TEST_SCENARIO="${CMAKE_CURRENT_SOURCE_DIR}/scenario.json"
    HAFEN_TEST_ARTIFACT_DIR="${CMAKE_CURRENT_BINARY_DIR}/artifacts"
    HAFEN_TEST_QM_DIR="${CMAKE_BINARY_DIR}"
)
target_link_libraries(hafen_uitest PRIVATE hafencore hafencoreplugin Qt6::QuickTest)

add_test(NAME ui
    COMMAND ${HAFEN_DBUS_RUN_SESSION} --config-file=${CMAKE_CURRENT_SOURCE_DIR}/dbus-session.conf -- $<TARGET_FILE:hafen_uitest>)
set_tests_properties(ui PROPERTIES TIMEOUT 300)

add_test(NAME model
    COMMAND ${HAFEN_NODE} --test ${CMAKE_SOURCE_DIR}/tests/model.test.mjs)
