/* SPDX-License-Identifier: MIT */
#ifndef HAKIOS_USBMUX_WATCHDOG_H
#define HAKIOS_USBMUX_WATCHDOG_H
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static volatile sig_atomic_t hwatch_child;
extern char **environ;
static inline int hwatch_run(const char *path,char *const args[],volatile sig_atomic_t *stop,
    unsigned limit,unsigned pause_ms){
 unsigned attempts=0;if(!path||!args||!stop||pause_ms<1||pause_ms>60000)return -1;
 while(!*stop && (!limit || attempts<limit)){
  /* Match the phone's existing command runner; iOS does not require fork(). */
  pid_t child=0;int error=posix_spawn(&child,path,NULL,NULL,args,environ);
  if(error){errno=error;return -1;}
  hwatch_child=(sig_atomic_t)child;
  int status=0;
  if(*stop)kill(child,SIGTERM);
  while(waitpid(child,&status,0)<0){if(errno!=EINTR){hwatch_child=0;return -1;}if(*stop)kill(child,SIGTERM);}
  hwatch_child=0;attempts++;
  if(*stop|| (limit&&attempts>=limit))break;
  struct timespec wait={pause_ms/1000,(long)(pause_ms%1000)*1000000};
  while(!*stop && nanosleep(&wait,&wait)<0 && errno==EINTR){}
 }
 return (int)attempts;
}
#endif
