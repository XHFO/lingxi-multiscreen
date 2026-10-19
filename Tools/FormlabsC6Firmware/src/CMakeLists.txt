set(BASE "${CMAKE_CURRENT_LIST_DIR}/../../WaveshareC6Firmware/src")
set(RENDER "${CMAKE_CURRENT_LIST_DIR}/../../../Sources/C6DisplayRenderer")
idf_component_register(SRCS
    "captive_dns.c"
    "${BASE}/main.c" "${BASE}/standalone.c" "${BASE}/local_state.c"
    "${BASE}/local_sources.c" "${BASE}/local_updates.c"
    "${BASE}/thumbnail_api.c" "${BASE}/thumbnail_cache.c"
    "${BASE}/wifi_scan.c" "${BASE}/formlabs_source.c" "${BASE}/png_thumbnail.c"
    "${RENDER}/c6_display_renderer.c" "${RENDER}/qrcodegen.c"
    INCLUDE_DIRS "." "${BASE}" "${RENDER}/include")
target_compile_definitions(${COMPONENT_LIB} PRIVATE C6_FORMLABS_ONLY=1)
