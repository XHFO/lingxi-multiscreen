#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>
#define C6_FORM_AUTH_SLOTS 3
typedef struct {char key[17],token[1024];uint64_t expires;} c6_form_auth_entry_t;
typedef struct {c6_form_auth_entry_t entries[C6_FORM_AUTH_SLOTS];} c6_form_auth_cache_t;
static inline bool c6_form_auth_get(const c6_form_auth_cache_t *c,const char *key,uint64_t now,char token[1024],uint64_t *expires){
    for(unsigned i=0;i<C6_FORM_AUTH_SLOTS;i++)if(!strcmp(c->entries[i].key,key)&&*c->entries[i].token&&c->entries[i].expires>now+120){
        memcpy(token,c->entries[i].token,1024);*expires=c->entries[i].expires;return true;
    }return false;
}
static inline void c6_form_auth_put(c6_form_auth_cache_t *c,unsigned slot,const char *key,const char *token,uint64_t expires){
    if(slot>=C6_FORM_AUTH_SLOTS)return;
    memset(&c->entries[slot],0,sizeof(c->entries[slot]));
    if(token&&*token){snprintf(c->entries[slot].key,17,"%s",key);snprintf(c->entries[slot].token,1024,"%s",token);c->entries[slot].expires=expires;}
}
static inline void c6_form_auth_reject(c6_form_auth_cache_t *c,const char *key){
    for(unsigned i=0;i<C6_FORM_AUTH_SLOTS;i++)if(!strcmp(c->entries[i].key,key))memset(&c->entries[i],0,sizeof(c->entries[i]));
}
