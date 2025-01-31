cmake_minimum_required(VERSION 3.15)

set(FORTRAN_COMPILERS "gfortran" "ifort")

set(COMPILER_FOUND FALSE)

foreach(compiler_name ${FORTRAN_COMPILERS})
    find_program(FOUND_COMPILER ${compiler_name})
    if(FOUND_COMPILER)
        set(CMAKE_Fortran_COMPILER ${FOUND_COMPILER} CACHE STRING "Path to the Fortran compiler" FORCE)
        message(STATUS "Found Fortran compiler: ${FOUND_COMPILER}")
        set(COMPILER_FOUND TRUE)
        break()
    endif()
endforeach()

if(NOT COMPILER_FOUND)
    message(FATAL_ERROR "Could not find any of the specified Fortran compilers: ${FORTRAN_COMPILERS}")
endif()

project(sheap
        VERSION 1.0 
        DESCRIPTION "Sheap project using Fortran" 
        LANGUAGES Fortran)

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${PROJECT_SOURCE_DIR}/bin)

set(CMAKE_Fortran_FLAGS "${CMAKE_Fortran_FLAGS} -std=f2008")
set(CMAKE_Fortran_FLAGS "${CMAKE_Fortran_FLAGS} -ffree-line-length-none")
set(CMAKE_Fortran_FLAGS "${CMAKE_Fortran_FLAGS} -O3 -g -fexternal-blas -march=native -ffast-math -funroll-loops")
set(CMAKE_Fortran_FLAGS "${CMAKE_Fortran_FLAGS} -fopenmp")

find_package(OpenMP REQUIRED)
find_package(MPI REQUIRED)
find_package(BLAS REQUIRED)
find_package(LAPACK REQUIRED)

include(CTest)
enable_testing()

add_subdirectory(src)
add_subdirectory(test)
