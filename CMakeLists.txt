# SPDX-License-Identifier: GPL-3.0-or-later

cmake_minimum_required(VERSION 3.21)
project(hafen VERSION 0.3.1 LANGUAGES CXX
    DESCRIPTION "Docker-Container nach Compose-Projekt im Tray"
    HOMEPAGE_URL "https://github.com/bdgraue/Hafen")

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Widgets Network Qml Quick QuickControls2 LinguistTools)
find_package(KF6StatusNotifierItem REQUIRED)
find_package(KF6DBusAddons REQUIRED)
find_package(KF6Kirigami REQUIRED)

qt_standard_project_setup(REQUIRES 6.5)

# The app's QML module and C++ types live in a static library, so the UI tests link the same code as the app.
qt_add_library(hafencore STATIC)

# NO_CACHEGEN: compiled QML links Qt's private API, which ties the package to one exact Qt patch release
# (qt6-declarative-private-abi) and breaks it on every distribution Qt update. Hafen's QML is small enough to compile at start.
qt_add_qml_module(hafencore
    URI Hafen
    VERSION 1.0
    NO_CACHEGEN
    QML_FILES src/Main.qml src/model.mjs
    SOURCES src/docker.h src/docker.cpp src/launcher.h src/launcher.cpp src/tray.h src/tray.cpp
    RESOURCES data/hafen.svg
)

target_include_directories(hafencore PUBLIC src)
target_link_libraries(hafencore PUBLIC
    Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Network Qt6::Qml Qt6::Quick Qt6::QuickControls2
    KF6::StatusNotifierItem
)

qt_add_executable(hafen src/main.cpp)
target_compile_definitions(hafen PRIVATE HAFEN_VERSION="${PROJECT_VERSION}")
# Linking the plugin target also registers the statically linked QML module.
target_link_libraries(hafen PRIVATE hafencore hafencoreplugin KF6::DBusAddons)

# Every i18n/hafen_<language>.ts is compiled into the binary; a new language needs only its file (see README).
# `cmake --build build --target update_translations` adds new source texts to all of them.
file(GLOB HAFEN_TS_FILES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/i18n/hafen_*.ts")
qt_add_translations(hafen
    TS_FILES ${HAFEN_TS_FILES}
    SOURCE_TARGETS hafen hafencore
    LUPDATE_OPTIONS -no-obsolete -locations none
)

include(CTest)
if(BUILD_TESTING)
    add_subdirectory(tests/ui)
endif()

include(GNUInstallDirs)
install(TARGETS hafen RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES data/io.github.bdgraue.Hafen.desktop DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
install(FILES data/io.github.bdgraue.Hafen.metainfo.xml DESTINATION ${CMAKE_INSTALL_DATADIR}/metainfo)
install(FILES data/hafen.svg DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps RENAME io.github.bdgraue.Hafen.svg)

# `cpack -G DEB` in the build directory packages exactly what `cmake --install` installs.
set(CPACK_PACKAGE_NAME hafen)
set(CPACK_PACKAGE_VENDOR "Hafen contributors")
set(CPACK_PACKAGE_CONTACT "bdgraue <bdgraue@users.noreply.github.com>")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "${PROJECT_DESCRIPTION}")
set(CPACK_RESOURCE_FILE_LICENSE "${CMAKE_SOURCE_DIR}/LICENSE")
set(CPACK_PACKAGING_INSTALL_PREFIX /usr)
set(CPACK_DEBIAN_FILE_NAME DEB-DEFAULT)
set(CPACK_DEBIAN_PACKAGE_SECTION utils)
set(CPACK_DEBIAN_PACKAGE_HOMEPAGE "${PROJECT_HOMEPAGE_URL}")
set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)
# QML modules are loaded at runtime, so dpkg-shlibdeps cannot see them.
set(CPACK_DEBIAN_PACKAGE_DEPENDS
    "qml6-module-org-kde-kirigami, qml6-module-org-kde-desktop, qml6-module-qtquick, qml6-module-qtquick-controls, qml6-module-qtquick-layouts, qml6-module-qtquick-templates, qml6-module-qtcore, qml6-module-qtqml, qml6-module-qtqml-models")
set(CPACK_DEBIAN_PACKAGE_RECOMMENDS "docker-ce-cli | docker.io")
include(CPack)
