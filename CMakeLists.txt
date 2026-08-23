cmake_minimum_required(VERSION 3.22)
project(X360ReceiverBridge VERSION 0.2.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(APPLE AND NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING
        "Minimum supported macOS version")
endif()

option(X360BRIDGE_BUILD_APP "Build the receiver bridge executable" ON)
option(X360BRIDGE_BUILD_TESTS "Build protocol unit tests" ON)
set(X360BRIDGE_BUNDLE_IDENTIFIER "org.x360receiverbridge.app" CACHE STRING
    "Bundle identifier used for the macOS helper app")

find_package(Threads REQUIRED)

add_library(x360_protocol STATIC
    src/protocol.cpp
    src/hid_report.cpp
)
target_include_directories(x360_protocol PUBLIC include)
target_compile_options(x360_protocol PRIVATE
    $<$<CXX_COMPILER_ID:AppleClang,Clang,GNU>:-Wall;-Wextra;-Wpedantic>
)

if(X360BRIDGE_BUILD_APP)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(LIBUSB REQUIRED IMPORTED_TARGET libusb-1.0)

    set(X360BRIDGE_PLATFORM_SOURCE src/virtual_gamepad_stub.cpp)
    if(APPLE)
        enable_language(OBJCXX)
        enable_language(Swift)
        set(X360BRIDGE_PLATFORM_SOURCE src/virtual_gamepad_macos.mm)
    else()
        message(STATUS
            "Building the USB decoder with a no-HID stub; virtual gamepad output is macOS-only")
    endif()

    set(X360BRIDGE_APP_SOURCES
        src/main.cpp
        src/receiver.cpp
        src/wired_controller.cpp
        ${X360BRIDGE_PLATFORM_SOURCE}
    )
    if(APPLE)
        list(APPEND X360BRIDGE_APP_SOURCES
            src/macos_app.mm
            src/DeveloperLabEnvironment.swift
            src/X360DiagnosticDSUServer.swift
            src/X360BridgeApp.swift
        )
    endif()

    add_executable(x360receiverbridge
        ${X360BRIDGE_APP_SOURCES}
    )
    target_include_directories(x360receiverbridge PRIVATE include src)
    target_link_libraries(x360receiverbridge PRIVATE
        x360_protocol
        Threads::Threads
        PkgConfig::LIBUSB
    )
    target_compile_options(x360receiverbridge PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:-Wall;-Wextra;-Wpedantic>
    )

    if(APPLE)
        set_target_properties(x360receiverbridge PROPERTIES
            OUTPUT_NAME "X360 Controller Bridge"
            MACOSX_BUNDLE TRUE
            MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/cmake/Info.plist.in"
            MACOSX_BUNDLE_BUNDLE_NAME "X360 Controller Bridge"
            MACOSX_BUNDLE_GUI_IDENTIFIER "${X360BRIDGE_BUNDLE_IDENTIFIER}"
            MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
            MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
            MACOSX_BUNDLE_LONG_VERSION_STRING "${CMAKE_OSX_DEPLOYMENT_TARGET}"
        )
        target_compile_definitions(x360receiverbridge PRIVATE
            $<$<COMPILE_LANGUAGE:CXX>:X360BRIDGE_APPKIT_MAIN=1>
            $<$<COMPILE_LANGUAGE:OBJCXX>:X360BRIDGE_APPKIT_MAIN=1>
        )
        target_link_libraries(x360receiverbridge PRIVATE
            "-framework AppKit"
            "-framework ApplicationServices"
            "-framework QuartzCore"
            "-framework IOKit"
            "-framework CoreFoundation"
            "-framework Foundation"
            "-framework Security"
        )
        target_compile_options(x360receiverbridge PRIVATE
            $<$<COMPILE_LANGUAGE:OBJCXX>:-Wall;-Wextra;-Wpedantic;-fobjc-arc>
        )
        set_target_properties(x360receiverbridge PROPERTIES
            XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS
                "${CMAKE_SOURCE_DIR}/entitlements/X360ReceiverBridge.entitlements"
            XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER
                "${X360BRIDGE_BUNDLE_IDENTIFIER}"
            Swift_LANGUAGE_VERSION 5
        )
        target_compile_options(x360receiverbridge PRIVATE
            $<$<COMPILE_LANGUAGE:Swift>:-parse-as-library;-import-objc-header;${CMAKE_SOURCE_DIR}/src/X360Bridge-Bridging-Header.h>
        )
    endif()
endif()

if(X360BRIDGE_BUILD_TESTS)
    enable_testing()
    add_executable(protocol_tests tests/protocol_tests.cpp)
    target_link_libraries(protocol_tests PRIVATE x360_protocol Threads::Threads)
    target_compile_options(protocol_tests PRIVATE
        $<$<CXX_COMPILER_ID:AppleClang,Clang,GNU>:-Wall;-Wextra;-Wpedantic>
    )
    add_test(NAME protocol_tests COMMAND protocol_tests)
endif()
