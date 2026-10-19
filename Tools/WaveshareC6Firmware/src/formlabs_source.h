#pragma once
#include "local_state.h"
// Parse the same Dashboard response as the Mac, with bounded strings and no credentials.
bool c6_formlabs_update(c6_printer_state_t *state,cJSON *root,const char *serial,uint64_t now,char *picture,size_t capacity);
bool c6_formlabs_picture_url(const char *raw,char *url,size_t capacity,bool *bearer);
bool c6_formlabs_form_body(const char *id,const char *secret,char *body,size_t capacity);
