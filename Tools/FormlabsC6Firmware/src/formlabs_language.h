#pragma once
// Included on the HTTP display owner, after setup_request(). A narrow write
// capability only: no LAN token, credentials or other settings on the AP.
static esp_err_t terminal_language_response(httpd_req_t *req){
    char json[64];snprintf(json,sizeof(json),"{\"revision\":%d,\"language\":%d}",standalone_config.revision,standalone_config.language);
    httpd_resp_set_type(req,"application/json");httpd_resp_set_hdr(req,"Cache-Control","no-store");
    return httpd_resp_sendstr(req,json);
}
static esp_err_t terminal_language_handler(httpd_req_t *req){
    char header[32],host[80],origin[96],expected[96];
    if(httpd_req_get_hdr_value_str(req,"X-XH-Language",header,sizeof(header))!=ESP_OK||strcmp(header,"1")||
       httpd_req_get_hdr_value_str(req,"Host",host,sizeof(host))!=ESP_OK)
        return httpd_resp_send_err(req,HTTPD_403_FORBIDDEN,"Open the device settings page first");
    snprintf(expected,sizeof(expected),"http://%s",host);
    if(httpd_req_get_hdr_value_len(req,"Origin")&&
       (httpd_req_get_hdr_value_str(req,"Origin",origin,sizeof(origin))!=ESP_OK||strcmp(origin,expected)))
        return httpd_resp_send_err(req,HTTPD_403_FORBIDDEN,"Same-origin language change required");
    char *port=strchr(host,':');if(port){if(strcmp(port,":80"))return httpd_resp_send_err(req,HTTPD_403_FORBIDDEN,"Invalid host");*port=0;}
    bool ap=setup_request(req);
    if(ap?strcmp(host,"192.168.4.1")!=0:!standalone_lan_pairing_allowed(req))
        return httpd_resp_send_err(req,HTTPD_403_FORBIDDEN,"Use the setup hotspot or device LAN");
    char body[96];
    if(req->content_len<=0||req->content_len>=sizeof(body))return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid language request");
    int count=0;while(count<req->content_len){int n=httpd_req_recv(req,body+count,req->content_len-count);if(n<=0)return ESP_FAIL;count+=n;}
    if(memchr(body,0,count))return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid JSON");
    body[count]=0;cJSON *json=cJSON_ParseWithOpts(body,NULL,true);
    cJSON *rev=cJSON_GetObjectItemCaseSensitive(json,"revision"),*lang=cJSON_GetObjectItemCaseSensitive(json,"language");
    bool valid=cJSON_IsObject(json)&&cJSON_GetArraySize(json)==2&&cJSON_IsNumber(rev)&&cJSON_IsNumber(lang)&&
        rev->valuedouble>=0&&rev->valuedouble<INT_MAX-1&&rev->valuedouble==rev->valueint&&
        (lang->valuedouble==0||lang->valuedouble==1);
    int wanted=valid?lang->valueint:0,revision=valid?rev->valueint:0;cJSON_Delete(json);
    if(!valid)return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Expected revision and language 0 or 1");
    if(revision!=standalone_config.revision){httpd_resp_set_status(req,"409 Conflict");return terminal_language_response(req);}
    if(wanted!=standalone_config.language){
        unsigned mask=0;for(unsigned i=0;i<standalone_config.printer_count;i++)if(standalone_config.printers[i].rotate)mask|=1U<<i;
        if(!standalone_save_display_language(revision,standalone_config.rotation,standalone_config.flip_animation,standalone_config.card_mask,mask,wanted))
            return httpd_resp_send_err(req,HTTPD_500_INTERNAL_SERVER_ERROR,"Language not saved; retry");
        // Redraw current card, physical menu and either setup QR, without
        // reconnecting cloud sources or discarding the physical menu draft.
        c6_sources_display_options(standalone_config.revision,standalone_config.flip_animation);
        network_notice_drawn=false;setup_notice_drawn=false;last_clock_second=UINT32_MAX;
        menu_draft.language=wanted;
        if(menu_draft.revision==revision)menu_draft.revision=standalone_config.revision;
        device_menu.revision++;view_revision++;
    }
    return terminal_language_response(req);
}
