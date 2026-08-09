cmake_minimum_required(VERSION 3.20)
project(tessera-studio-linux C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(TESSERA_LINUX_BUILD_UI "Build GTK4/Adwaita UI" ON)

find_package(PkgConfig QUIET)

if(PkgConfig_FOUND)
    pkg_check_modules(GTK4 gtk4)
    pkg_check_modules(ADWAITA libadwaita-1)
    pkg_check_modules(GTKSOURCEVIEW gtksourceview-5)
    pkg_check_modules(LIBSECRET libsecret-1)
    pkg_check_modules(LIBSOUP libsoup-3.0)
    pkg_check_modules(EDS libecal-2.0 libebook-1.2 libedataserver-1.2)
    pkg_check_modules(LIBETPAN libetpan)
    pkg_check_modules(ATSPI atspi-2)
    pkg_check_modules(LIBPQ libpq)
    pkg_check_modules(HIREDIS hiredis)
    pkg_check_modules(WEBKIT webkitgtk-6.0)
    pkg_check_modules(DUCKDB duckdb)
endif()

# Core library (no GTK deps) — C0..M7 full parity (all REQUIRED backends)
add_library(tessera-core-linux STATIC
    src/core/config.cpp
    src/core/cli_resolver.cpp
    src/ffi/ctessera/shim.cpp
    src/core/provider.cpp
    src/core/agent/Agent.cpp
    src/core/engine/Engine.cpp
    src/core/ops/Calibration.cpp
    src/core/ops/Capacity.cpp
    src/core/data/DataLayer.cpp
    src/core/encryption/Secrets.cpp
    src/core/encryption/Volume.cpp
    src/core/productivity/Productivity.cpp
    src/core/productivity/OAuth.cpp
    src/core/productivity/docs/DocStore.cpp
    src/core/productivity/sheets/SheetStore.cpp
    src/core/productivity/slides/SlideStore.cpp
    src/core/agent/tools/DesktopTool.cpp
    src/core/agent/tools/BrowserTool.cpp
    src/core/agent/ToolRegistry.cpp
    src/core/data/KnowledgeSync.cpp
    src/core/system/BackgroundPortal.cpp
    src/core/learning/TraceStore.cpp
    src/core/learning/Curation.cpp
    src/core/workflow/StateGraph.cpp
    src/core/moe/MoE.cpp
    src/core/moe/DeviceRegistry.cpp
    src/core/moe/RegimeManager.cpp
    src/core/moe/Dispatcher.cpp
    src/core/hardware/HardwareProber.cpp
    src/core/hardware/TilingRepacker.cpp
)

target_include_directories(tessera-core-linux PUBLIC
    src
    src/core
    src/ffi/ctessera
)
if(EDS_FOUND)
    target_include_directories(tessera-core-linux PRIVATE ${EDS_INCLUDE_DIRS})
    target_link_libraries(tessera-core-linux PRIVATE ${EDS_LIBRARIES})
    target_compile_definitions(tessera-core-linux PRIVATE HAVE_EDS=1)
endif()
if(LIBETPAN_FOUND)
    target_include_directories(tessera-core-linux PRIVATE ${LIBETPAN_INCLUDE_DIRS})
    target_link_libraries(tessera-core-linux PRIVATE ${LIBETPAN_LIBRARIES})
    target_compile_definitions(tessera-core-linux PRIVATE HAVE_LIBETPAN=1)
endif()
if(LIBSECRET_FOUND)
    target_include_directories(tessera-core-linux PRIVATE ${LIBSECRET_INCLUDE_DIRS})
    target_link_libraries(tessera-core-linux PRIVATE ${LIBSECRET_LIBRARIES})
    target_compile_definitions(tessera-core-linux PRIVATE HAVE_LIBSECRET=1)
endif()
if(ATSPI_FOUND)
    target_include_directories(tessera-core-linux PRIVATE ${ATSPI_INCLUDE_DIRS})
    target_link_libraries(tessera-core-linux PRIVATE ${ATSPI_LIBRARIES})
    target_compile_definitions(tessera-core-linux PRIVATE HAVE_ATSPI=1)
endif()
if(LIBSOUP_FOUND)
    target_include_directories(tessera-core-linux PRIVATE ${LIBSOUP_INCLUDE_DIRS})
    target_link_libraries(tessera-core-linux PRIVATE ${LIBSOUP_LIBRARIES})
    target_compile_definitions(tessera-core-linux PRIVATE HAVE_LIBSOUP=1)
endif()
if(LIBPQ_FOUND)
    target_include_directories(tessera-core-linux PRIVATE ${LIBPQ_INCLUDE_DIRS})
    target_link_libraries(tessera-core-linux PRIVATE ${LIBPQ_LIBRARIES})
    target_compile_definitions(tessera-core-linux PRIVATE HAVE_LIBPQ=1)
endif()
if(HIREDIS_FOUND)
    target_include_directories(tessera-core-linux PRIVATE ${HIREDIS_INCLUDE_DIRS})
    target_link_libraries(tessera-core-linux PRIVATE ${HIREDIS_LIBRARIES})
    target_compile_definitions(tessera-core-linux PRIVATE HAVE_HIREDIS=1)
endif()
if(WEBKIT_FOUND)
    target_include_directories(tessera-core-linux PRIVATE ${WEBKIT_INCLUDE_DIRS})
    target_link_libraries(tessera-core-linux PRIVATE ${WEBKIT_LIBRARIES})
    target_compile_definitions(tessera-core-linux PRIVATE HAVE_WEBKIT=1)
endif()

# FFI + engine bridge already in core lib above

# UI executable (only if GTK4+Adwaita found)
if(GTK4_FOUND AND ADWAITA_FOUND AND TESSERA_LINUX_BUILD_UI)
    add_executable(tessera-studio-linux
        src/app/AppMain.cpp
        src/ui/surfaces/chat/ChatView.cpp
        src/ui/surfaces/editor/Editor.cpp
        src/ui/surfaces/editor/EditorSurface.cpp
        src/ui/surfaces/workflow/Workflow.cpp
        src/ui/widgets/ChatBubble.cpp
        src/ui/surfaces/learning/Surface.cpp
        src/ui/surfaces/graph/GraphView.cpp
        src/ui/surfaces/settings/Surface.cpp
        src/ui/surfaces/code/CodeSurface.cpp
        src/ui/surfaces/workflow/WorkflowSurface.cpp
        src/ui/surfaces/notes/NotesSurface.cpp
        src/ui/surfaces/email/EmailSurface.cpp
        src/ui/surfaces/tasks/Surface.cpp
        src/ui/surfaces/calendar/CalendarSurface.cpp
        src/ui/surfaces/contacts/ContactsSurface.cpp
        src/ui/surfaces/reminders/RemindersSurface.cpp
        src/ui/surfaces/providers/Surface.cpp
        src/ui/surfaces/models/Surface.cpp
        src/ui/surfaces/capacity/Surface.cpp
        src/ui/surfaces/collab/Surface.cpp
        src/ui/surfaces/docs/DocsSurface.cpp
        src/ui/surfaces/sheets/SheetsSurface.cpp
        src/ui/surfaces/receipts/ReceiptsSurface.cpp
        src/ui/surfaces/receipts/Surface.cpp
    )

    target_include_directories(tessera-studio-linux PRIVATE
        src
        src/app
        src/core
        src/ui
    )

    target_link_libraries(tessera-studio-linux PRIVATE
        tessera-core-linux
        ${GTK4_LIBRARIES}
        ${ADWAITA_LIBRARIES}
        ${GTKSOURCEVIEW_LIBRARIES}
        ${LIBSECRET_LIBRARIES}
        ${EDS_LIBRARIES}
        ${LIBETPAN_LIBRARIES}
    )
    if(LIBSOUP_FOUND)
        target_link_libraries(tessera-studio-linux PRIVATE ${LIBSOUP_LIBRARIES})
    endif()

    target_include_directories(tessera-studio-linux PRIVATE
        ${GTK4_INCLUDE_DIRS}
        ${ADWAITA_INCLUDE_DIRS}
        ${GTKSOURCEVIEW_INCLUDE_DIRS}
        ${LIBSECRET_INCLUDE_DIRS}
        ${EDS_INCLUDE_DIRS}
        ${LIBETPAN_INCLUDE_DIRS}
    )
    if(LIBSOUP_FOUND)
        target_include_directories(tessera-studio-linux PRIVATE ${LIBSOUP_INCLUDE_DIRS})
    endif()

    if(EDS_FOUND)
        target_compile_definitions(tessera-studio-linux PRIVATE HAVE_EDS=1)
    endif()
    if(LIBETPAN_FOUND)
        target_compile_definitions(tessera-studio-linux PRIVATE HAVE_LIBETPAN=1)
    endif()
    if(LIBSOUP_FOUND)
        target_compile_definitions(tessera-studio-linux PRIVATE HAVE_LIBSOUP=1)
    endif()
    if(LIBSECRET_FOUND)
        target_compile_definitions(tessera-studio-linux PRIVATE HAVE_LIBSECRET=1)
    endif()
    if(ATSPI_FOUND)
        target_compile_definitions(tessera-studio-linux PRIVATE HAVE_ATSPI=1)
    endif()
    target_compile_definitions(tessera-studio-linux PRIVATE HAVE_GTK=1)
    target_compile_options(tessera-studio-linux PRIVATE
        ${GTK4_CFLAGS_OTHER}
        ${ADWAITA_CFLAGS_OTHER}
    )

    # GSettings schema + desktop + metainfo + icon (first-class Fedora desktop)
    include(GNUInstallDirs)
    install(FILES res/org.tessera.TesseraStudio.gschema.xml
        DESTINATION ${CMAKE_INSTALL_DATADIR}/glib-2.0/schemas
    )
    install(FILES res/org.tessera.TesseraStudio.desktop
        DESTINATION ${CMAKE_INSTALL_DATADIR}/applications
    )
    install(FILES res/org.tessera.TesseraStudio.metainfo.xml
        DESTINATION ${CMAKE_INSTALL_DATADIR}/metainfo
    )
    install(FILES res/icons/hicolor/512x512/apps/org.tessera.TesseraStudio.png
        DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/512x512/apps
    )
    install(FILES res/icons/hicolor/scalable/apps/org.tessera.TesseraStudio.svg
        DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps
    )
    foreach(SZ 16 32 64 128 256)
        install(FILES res/icons/hicolor/${SZ}x${SZ}/apps/org.tessera.TesseraStudio.png
            DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/${SZ}x${SZ}/apps
        )
    endforeach()
    install(FILES res/icons/hicolor/symbolic/apps/org.tessera.TesseraStudio-symbolic.svg
        DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/symbolic/apps
    )
    install(FILES res/systemd/user/tessera-agent.service DESTINATION ${CMAKE_INSTALL_DATADIR}/systemd/user)
    install(TARGETS tessera-studio-linux RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

    message(STATUS "Tessera Linux UI: ENABLED (gtk4 ${GTK4_VERSION} / adwaita ${ADWAITA_VERSION})")
else()
    message(STATUS "Tessera Linux UI: DISABLED (missing gtk4/adwaita) — core library only")
    if(NOT GTK4_FOUND)
        message(STATUS "  gtk4 not found: sudo dnf install gtk4-devel")
    endif()
    if(NOT ADWAITA_FOUND)
        message(STATUS "  libadwaita not found: sudo dnf install libadwaita-devel")
    endif()
endif()

# Tests
enable_testing()
add_subdirectory(tests)
