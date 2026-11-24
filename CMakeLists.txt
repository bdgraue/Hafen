# SPDX-License-Identifier: GPL-3.0-or-later

cmake_minimum_required(VERSION 3.21)
project(hafen VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Widgets Qml Quick QuickControls2)
find_package(KF6StatusNotifierItem REQUIRED)
find_package(KF6DBusAddons REQUIRED)
find_package(KF6Kirigami REQUIRED)

qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(hafen src/main.cpp)

qt_add_qml_module(hafen
    URI Hafen
    VERSION 1.0
    QML_FILES src/Main.qml src/model.mjs
    SOURCES src/docker.h src/docker.cpp src/tray.h src/tray.cpp
    RESOURCES data/hafen.svg
)

target_include_directories(hafen PRIVATE src)

target_link_libraries(hafen PRIVATE
    Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Qml Qt6::Quick Qt6::QuickControls2
    KF6::StatusNotifierItem KF6::DBusAddons
)

include(GNUInstallDirs)
install(TARGETS hafen RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES data/hafen.desktop DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
install(FILES data/hafen.svg DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps)
