cmake_minimum_required(VERSION 3.16)
set(PROJECT_VER "2.0.0-formlabs-alpha.14")
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# A distinct project name rejects accidentally cross-flashing normal C6 OTA.
project(lingxi_c6_formlabs)
