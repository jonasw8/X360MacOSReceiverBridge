cmake_minimum_required(VERSION 3.22)
project(X360ReceiverBridge VERSION 0.1.2 LANGUAGES CXX)

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
        set(X360BRIDGE_PLATFORM_SOURCE src/virtual_gamepad_macos.mm)
    else()
        message(STATUS
            "Building the USB decoder with a no-HID stub; virtual gamepad output is macOS-only")
    endif()

    add_executable(x360receiverbridge
        src/main.cpp
        src/receiver.cpp
        ${X360BRIDGE_PLATFORM_SOURCE}
    )
    target_include_directories(x360receiverbridge PRIVATE include)
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
            MACOSX_BUNDLE TRUE
            MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/cmake/Info.plist.in"
            MACOSX_BUNDLE_BUNDLE_NAME "X360ReceiverBridge"
            MACOSX_BUNDLE_GUI_IDENTIFIER "${X360BRIDGE_BUNDLE_IDENTIFIER}"
            MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
            MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
            MACOSX_BUNDLE_LONG_VERSION_STRING "${CMAKE_OSX_DEPLOYMENT_TARGET}"
        )
        target_link_libraries(x360receiverbridge PRIVATE
            "-framework IOKit"
            "-framework CoreFoundation"
            "-framework Foundation"
        )
        target_compile_options(x360receiverbridge PRIVATE
            $<$<COMPILE_LANGUAGE:OBJCXX>:-Wall;-Wextra;-Wpedantic;-fobjc-arc>
        )
        set_target_properties(x360receiverbridge PROPERTIES
            XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS
                "${CMAKE_SOURCE_DIR}/entitlements/X360ReceiverBridge.entitlements"
            XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER
                "${X360BRIDGE_BUNDLE_IDENTIFIER}"
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
