#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef size_t (*c6_image_reader_t)(void *context,uint8_t *bytes,size_t count);
// Bounded streaming 8-bit PNG: RGB/RGBA/grayscale/palette, non-interlaced,
// <=1024 per edge. ROM inflate + two rows; never a full-resolution bitmap.
bool c6_png_thumbnail(c6_image_reader_t read,void *context,uint8_t *rgb565,unsigned *width,unsigned *height);
