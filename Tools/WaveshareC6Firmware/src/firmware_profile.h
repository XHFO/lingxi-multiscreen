#pragma once
#ifndef C6_FORMLABS_ONLY
#define C6_FORMLABS_ONLY 0
#endif
#if C6_FORMLABS_ONLY
#define C6_FIRMWARE_VERSION "2.0.0-formlabs-alpha.14"
#define C6_WEATHER_NAMESPACE "form_weather"
#define C6_WEATHER_EXTRA_FIELDS ",relative_humidity_2m,wind_speed_10m"
#define C6_DEVICE_ID "lingxi-c6-formlabs-monitor"
#define C6_CONFIG_NAMESPACE "form_monitor"
#define C6_DEFAULT_CARD_MASK 5
#define C6_DEFAULT_DIAGNOSTICS false
#define C6_DEFAULT_LOCAL_FIRST true
#define C6_CLOCK_FRAME_MS 33
#define C6_CLOCK_DURATION_US 720000
#else
#define C6_FIRMWARE_VERSION "2.0.0-alpha.20"
#define C6_WEATHER_NAMESPACE "weather"
#define C6_WEATHER_EXTRA_FIELDS ""
#define C6_DEVICE_ID "lingxi-esp32-c6-screen"
#define C6_CONFIG_NAMESPACE "standalone"
#define C6_DEFAULT_CARD_MASK 15
#define C6_DEFAULT_DIAGNOSTICS true
#define C6_DEFAULT_LOCAL_FIRST false
#define C6_CLOCK_FRAME_MS 33
#define C6_CLOCK_DURATION_US 720000
#endif
