#include <napi/native_api.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <linux/if_tun.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <memory>
#include <string>
#include <vector>

extern "C" {
char *SBVersion();
char *SBCheck(char *);
char *SBStart(char *, int, char *, char *);
char *SBStop();
void SBFree(char *);
}

enum class Operation { Version, Check, Start, Stop };
struct Job {
 napi_async_work work = nullptr;
 napi_deferred deferred = nullptr;
 Operation operation;
 std::string config, path, interfaceName, output;
 int fd = -1;
};

static napi_value Text(napi_env env, const std::string &text) {
 napi_value out;
 napi_create_string_utf8(env, text.c_str(), text.size(), &out);
 return out;
}
static bool StringArg(napi_env env, napi_value arg, std::string &out) {
 size_t length;
 if (napi_get_value_string_utf8(env,arg,nullptr,0,&length)!=napi_ok || length>1024*1024) return false;
 std::vector<char> buffer(length+1);
 if(napi_get_value_string_utf8(env,arg,buffer.data(),buffer.size(),&length)!=napi_ok) return false;
 out.assign(buffer.data(),length);
 return out.find('\0')==std::string::npos;
}
static void Execute(napi_env, void *data) {
 auto *job=static_cast<Job *>(data);
 char *value=nullptr;
 switch(job->operation) {
 case Operation::Version: value=SBVersion();break;
 case Operation::Check: value=SBCheck(job->config.data());break;
 case Operation::Start: value=SBStart(job->config.data(),job->fd,job->path.data(),job->interfaceName.data());break;
 case Operation::Stop: value=SBStop();break;
 }
 if(value){job->output=value;SBFree(value);}
 else job->output="{\"ok\":false,\"message\":\"内核未返回结果\"}";
}
static void Complete(napi_env env,napi_status status,void *data) {
 std::unique_ptr<Job> job(static_cast<Job *>(data));
 if(status==napi_ok) napi_resolve_deferred(env,job->deferred,Text(env,job->output));
 else napi_reject_deferred(env,job->deferred,Text(env,"原生任务取消"));
 napi_delete_async_work(env,job->work);
}
static napi_value Dispatch(napi_env env,napi_callback_info info,Operation operation) {
 size_t argc=4;napi_value argv[4];napi_get_cb_info(env,info,&argc,argv,nullptr,nullptr);
 auto job=std::make_unique<Job>();job->operation=operation;
 bool valid=true;
 if(operation==Operation::Check || operation==Operation::Start) valid=argc>=1 && StringArg(env,argv[0],job->config);
 if(operation==Operation::Start) valid=valid && argc==4 && napi_get_value_int32(env,argv[1],&job->fd)==napi_ok && job->fd>=0 && StringArg(env,argv[2],job->path) && StringArg(env,argv[3],job->interfaceName);
 if(!valid){napi_throw_type_error(env,nullptr,"无效的原生参数，配置上限 1 MiB");return nullptr;}
 napi_value promise;
 if(napi_create_promise(env,&job->deferred,&promise)!=napi_ok) return nullptr;
 if(napi_create_async_work(env,nullptr,Text(env,"sing-box"),Execute,Complete,job.get(),&job->work)!=napi_ok){napi_reject_deferred(env,job->deferred,Text(env,"无法创建内核任务"));return promise;}
 if(napi_queue_async_work(env,job->work)!=napi_ok){napi_reject_deferred(env,job->deferred,Text(env,"无法调度内核任务"));napi_delete_async_work(env,job->work);return promise;}
 job.release();return promise;
}
static napi_value Version(napi_env e,napi_callback_info i){return Dispatch(e,i,Operation::Version);}
static napi_value Check(napi_env e,napi_callback_info i){return Dispatch(e,i,Operation::Check);}
static napi_value Start(napi_env e,napi_callback_info i){return Dispatch(e,i,Operation::Start);}
static napi_value Stop(napi_env e,napi_callback_info i){return Dispatch(e,i,Operation::Stop);}
static napi_value TunName(napi_env env,napi_callback_info info){
 size_t argc=1;napi_value argv[1];int fd=-1;
 napi_get_cb_info(env,info,&argc,argv,nullptr,nullptr);
 if(argc!=1 || napi_get_value_int32(env,argv[0],&fd)!=napi_ok || fd<0){napi_throw_type_error(env,nullptr,"无效 TUN fd");return nullptr;}
 struct ifreq req{};
 if(ioctl(fd,TUNGETIFF,&req)<0){napi_throw_error(env,nullptr,"无法从系统 TUN 查询真实接口名");return nullptr;}
 return Text(env,req.ifr_name);
}
static napi_value Interfaces(napi_env env,napi_callback_info){
 struct ifaddrs *all=nullptr;
 if(getifaddrs(&all)!=0){napi_throw_error(env,nullptr,"无法查询网络接口");return nullptr;}
 std::string out="[";bool first=true;
 for(auto *it=all;it;it=it->ifa_next){
  if(!it->ifa_addr)continue;
  auto family=it->ifa_addr->sa_family;
  if(family!=AF_INET && family!=AF_INET6)continue;
  char address[INET6_ADDRSTRLEN]{};
  const void *raw=family==AF_INET?static_cast<void *>(&reinterpret_cast<sockaddr_in *>(it->ifa_addr)->sin_addr):static_cast<void *>(&reinterpret_cast<sockaddr_in6 *>(it->ifa_addr)->sin6_addr);
  if(!inet_ntop(family,raw,address,sizeof(address)))continue;
  std::string name=it->ifa_name;
  // Interface names come from the kernel; encode without JSON injection.
  if(name.find_first_of("\"\\\n\r")!=std::string::npos)continue;
  if(!first)out+=",";first=false;
  out+="{\"name\":\""+name+"\",\"family\":"+(family==AF_INET?std::string("4"):std::string("6"))+",\"address\":\""+address+"\"}";
 }
 freeifaddrs(all);out+="]";return Text(env,out);
}
static napi_value SecureFile(napi_env env,napi_callback_info info){
 size_t argc=1;napi_value argv[1];int fd=-1;
 napi_get_cb_info(env,info,&argc,argv,nullptr,nullptr);
 if(argc!=1 || napi_get_value_int32(env,argv[0],&fd)!=napi_ok || fd<0 || fchmod(fd,0600)!=0){napi_throw_error(env,nullptr,"无法设置配置文件权限");return nullptr;}
 napi_value value;napi_get_undefined(env,&value);return value;
}
static napi_value Init(napi_env env,napi_value exports){
 napi_property_descriptor methods[]={
  {"version",nullptr,Version,nullptr,nullptr,nullptr,napi_default,nullptr},
  {"check",nullptr,Check,nullptr,nullptr,nullptr,napi_default,nullptr},
  {"start",nullptr,Start,nullptr,nullptr,nullptr,napi_default,nullptr},
  {"stop",nullptr,Stop,nullptr,nullptr,nullptr,napi_default,nullptr},
  {"tunName",nullptr,TunName,nullptr,nullptr,nullptr,napi_default,nullptr},
  {"interfaces",nullptr,Interfaces,nullptr,nullptr,nullptr,napi_default,nullptr},
  {"secureFile",nullptr,SecureFile,nullptr,nullptr,nullptr,napi_default,nullptr}
 };
 napi_define_properties(env,exports,sizeof(methods)/sizeof(methods[0]),methods);return exports;
}
static napi_module module={1,0,nullptr,Init,"singboxbridge",nullptr,{0}};
extern "C" __attribute__((constructor)) void RegisterModule(){napi_module_register(&module);}
