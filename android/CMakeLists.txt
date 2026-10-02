cmake_minimum_required(VERSION 3.22.1)
project(dartnative_mobile_scanner)

add_library(dartnative_mobile_scanner SHARED
    src/main/cpp/dn_scanner_bridge.cpp
)

# find_library, not find_package(JNI): the NDK supplies the JNI headers, while
# find_package hunts for a host JDK and fails during cross-compilation.
find_library(log-lib log)

target_link_libraries(dartnative_mobile_scanner ${log-lib})
