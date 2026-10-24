#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *(*version)(void);
static char *(*check)(char *);
static void (*release)(char *);
static int success;
static void *worker(void *unused) {
 (void)unused;
 char *v=version();
 if(!v)return NULL;
 printf("version=%s\n",v);release(v);
 char config[]="{\"outbounds\":[{\"type\":\"direct\",\"tag\":\"direct\"}],\"route\":{\"final\":\"direct\"}}";
 char *r=check(config);
 if(r){printf("check=%s\n",r);success=strstr(r,"\"ok\":true")!=NULL;release(r);}
 return NULL;
}
int main(int argc,char **argv){
 if(argc!=2){fputs("usage: native-smoke /absolute/libsingbox.so\n",stderr);return 2;}
 void *lib=dlopen(argv[1],RTLD_LAZY|RTLD_LOCAL);
 if(!lib){fprintf(stderr,"dlopen: %s\n",dlerror());return 3;}
 version=dlsym(lib,"SBVersion");check=dlsym(lib,"SBCheck");release=dlsym(lib,"SBFree");
 if(!version || !check || !release){fputs("missing ABI symbol\n",stderr);return 4;}
 pthread_t thread;
 if(pthread_create(&thread,NULL,worker,NULL)!=0)return 5;
 pthread_join(thread,NULL);
 // Go c-shared runtimes are process-lifetime libraries; deliberately do not dlclose.
 return success?0:6;
}
