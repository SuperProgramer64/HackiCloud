/* SPDX-License-Identifier: MIT
 * The command channel must survive a daemon fault, without rebooting iOS.
 * This parent supervises only the fixed local daemon; no network/authentication API.
 */
#include "usbmux_watchdog.h"
#include <fcntl.h>
#include <sys/file.h>
static volatile sig_atomic_t stopping;
static void stop(int sig){(void)sig;stopping=1;if(hwatch_child>0)kill((pid_t)hwatch_child,SIGTERM);}
int main(void){
 int lock=open("/var/run/hakios-usbmux-watchdog.lock",O_CREAT|O_RDWR|O_NOFOLLOW,0600);
 if(lock<0)return 1;if(flock(lock,LOCK_EX|LOCK_NB))return 0;
 fcntl(lock,F_SETFD,FD_CLOEXEC);
 struct sigaction sa={0};sa.sa_handler=stop;sigemptyset(&sa.sa_mask);sigaction(SIGTERM,&sa,NULL);sigaction(SIGINT,&sa,NULL);
 char *args[]={"/redwood/bin/usbmuxd_dev",NULL};
 int result=hwatch_run(args[0],args,&stopping,0,1000);close(lock);return result<0?2:0;
}
