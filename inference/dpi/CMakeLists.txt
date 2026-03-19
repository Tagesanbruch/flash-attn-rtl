cmake_minimum_required(VERSION 3.20)
project(fa_dpi_backend LANGUAGES CXX)

option(FA_DPI_USE_VERILATOR "Build with real Verilator model" ON)
option(FA_DPI_USE_STUB_BACKEND "Use stub_src backend implementation" OFF)
option(FA_DPI_BUILD_TESTS "Build DPI smoke tests" ON)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(FA_DPI_USE_STUB_BACKEND)
  set(FA_DPI_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/stub_src)
else()
  set(FA_DPI_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/src)
endif()

if(FA_DPI_USE_VERILATOR)
  if(FA_DPI_USE_STUB_BACKEND)
    message(FATAL_ERROR "FA_DPI_USE_VERILATOR=ON conflicts with FA_DPI_USE_STUB_BACKEND=ON")
  endif()

  find_program(VERILATOR_EXECUTABLE verilator REQUIRED)
  execute_process(
    COMMAND ${VERILATOR_EXECUTABLE} -getenv VERILATOR_ROOT
    OUTPUT_VARIABLE VERILATOR_ROOT
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )

  set(FLASHATTN_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../..)
  set(VERILATED_MDIR ${CMAKE_BINARY_DIR}/verilated)
  set(VERILATED_LIB ${VERILATED_MDIR}/libVfa_attention_ip_top.a)
  set(VERILATED_RT_LIB ${VERILATED_MDIR}/libverilated.a)

  set(FA_TOP_RTL
    ${FLASHATTN_ROOT}/rtl/common/fa_fixed_point_pkg.sv
    ${FLASHATTN_ROOT}/rtl/common/fa_mul_sat_q8_8.sv
    ${FLASHATTN_ROOT}/rtl/softmax/fa_exp_pwl_8seg_q1_15.sv
    ${FLASHATTN_ROOT}/rtl/softmax/fa_recip_nr_q16_16.sv
    ${FLASHATTN_ROOT}/rtl/core/fa_qk_dotprod_slice.sv
    ${FLASHATTN_ROOT}/rtl/core/fa_online_softmax_ctx.sv
    ${FLASHATTN_ROOT}/rtl/core/fa_o_normalize_block.sv
    ${FLASHATTN_ROOT}/rtl/bus/fa_axi_lite_regs.sv
    ${FLASHATTN_ROOT}/rtl/bus/fa_dma_reader.sv
    ${FLASHATTN_ROOT}/rtl/bus/fa_dma_writer.sv
    ${FLASHATTN_ROOT}/rtl/core/fa_attention_core.sv
    ${FLASHATTN_ROOT}/rtl/top/fa_perf_counters.sv
    ${FLASHATTN_ROOT}/rtl/top/fa_attention_ip_top.sv
  )

  add_custom_command(
    OUTPUT ${VERILATED_LIB} ${VERILATED_RT_LIB}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${VERILATED_MDIR}
    COMMAND ${VERILATOR_EXECUTABLE}
            -cc
            --build
            --Mdir ${VERILATED_MDIR}
            --top-module fa_attention_ip_top
            -O3
            -Wno-WIDTHTRUNC
            -Wno-WIDTHEXPAND
            -Wno-UNUSEDSIGNAL
            ${FA_TOP_RTL}
    DEPENDS ${FA_TOP_RTL}
    WORKING_DIRECTORY ${FLASHATTN_ROOT}
    COMMENT "Verilating fa_attention_ip_top"
    VERBATIM
  )

  add_custom_target(verilate_fa_top DEPENDS ${VERILATED_LIB} ${VERILATED_RT_LIB})
endif()

add_library(fa_dpi_backend STATIC
  ${FA_DPI_SRC_DIR}/fa_dpi_backend.cpp
  ${FA_DPI_SRC_DIR}/fa_veri_top.cpp
  ${FA_DPI_SRC_DIR}/fa_axil_driver.cpp
  ${FA_DPI_SRC_DIR}/fa_task_queue_submit.cpp
  ${FA_DPI_SRC_DIR}/fa_dma_mem_model.cpp
)

target_include_directories(fa_dpi_backend
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
  PRIVATE
    ${FA_DPI_SRC_DIR}
)

if(FA_DPI_USE_VERILATOR)
  add_dependencies(fa_dpi_backend verilate_fa_top)
  target_compile_definitions(fa_dpi_backend PRIVATE FA_DPI_USE_VERILATOR=1)
  target_include_directories(fa_dpi_backend PRIVATE
    ${VERILATED_MDIR}
    ${VERILATOR_ROOT}/include
    ${VERILATOR_ROOT}/include/vltstd
  )
  target_link_libraries(fa_dpi_backend PRIVATE ${VERILATED_LIB} ${VERILATED_RT_LIB})
endif()

if(FA_DPI_BUILD_TESTS)
  enable_testing()
  add_executable(dpi_smoke tests/dpi_smoke.cpp)
  target_link_libraries(dpi_smoke PRIVATE fa_dpi_backend)
  target_include_directories(dpi_smoke PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  add_test(NAME dpi_smoke COMMAND dpi_smoke)

  add_executable(dpi_minvec_compare tests/dpi_minvec_compare.cpp)
  target_link_libraries(dpi_minvec_compare PRIVATE fa_dpi_backend)
  target_include_directories(dpi_minvec_compare PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)

  add_executable(dpi_lsb_stage_compare tests/dpi_lsb_stage_compare.cpp)
  target_link_libraries(dpi_lsb_stage_compare PRIVATE fa_dpi_backend)
  target_include_directories(dpi_lsb_stage_compare PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
endif()
