#ifndef HACKICLOUD_MAPPING_H
#define HACKICLOUD_MAPPING_H
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#define HC_ANON "/var/jb/usr/bin/hackicloud_anonymous akd"
#define HC_SIGN "/var/jb/usr/bin/hackicloud_signer Preferences"
/* Only own entries are replaced. A foreign hook on either target requires manual integration. */
static int hcloud_mapping(const char*input,char*out,size_t cap,int enable){
 if(!input||!out||!cap||strlen(input)>=8192)return 1;
 char*copy=strdup(input);if(!copy)return 1;out[0]=0;
 char*save=NULL;int result=0;
 for(char*p=strtok_r(copy,";",&save);p;p=strtok_r(NULL,";",&save)){
  while(isspace((unsigned char)*p))p++;size_t len=strlen(p);
  while(len&&isspace((unsigned char)p[len-1]))p[--len]=0;
  if(!len||!strcmp(p,HC_ANON)||!strcmp(p,HC_SIGN))continue;
  if(enable){char*targets=strchr(p,' ');if(targets){char*list=strdup(targets);if(!list){result=1;break;}char*s=NULL;
   for(char*t=strtok_r(list," \t",&s);t;t=strtok_r(NULL," \t",&s))if(!strcmp(t,"akd")||!strcmp(t,"Preferences"))result=2;
   free(list);if(result)break;
  }}
  size_t n=strlen(out);if(n+len+(n?2:0)+1>cap){result=1;break;}if(n)strcat(out,"; ");strcat(out,p);
 }
 free(copy);if(result)return result;
 if(enable){size_t n=strlen(out);if(n+strlen(HC_ANON)+strlen(HC_SIGN)+(n?4:2)+1>cap)return 1;if(n)strcat(out,"; ");strcat(out,HC_ANON);strcat(out,"; ");strcat(out,HC_SIGN);}
 return 0;
}
#endif
