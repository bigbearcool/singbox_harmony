package main

/*
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <string.h>
static int sb_mtu(int fd,const char *name){
 struct ifreq req={0};strncpy(req.ifr_name,name,IFNAMSIZ-1);
 if(ioctl(fd,SIOCGIFMTU,&req)<0)return 1280;
 return req.ifr_mtu;
}
static int sb_address(struct ifaddrs *it,char *out){
 if(!it->ifa_addr)return 0;
 int family=it->ifa_addr->sa_family;
 const void *address=NULL,*mask=NULL;int size=0;
 if(family==AF_INET){address=&((struct sockaddr_in*)it->ifa_addr)->sin_addr;size=4;if(it->ifa_netmask)mask=&((struct sockaddr_in*)it->ifa_netmask)->sin_addr;}
 else if(family==AF_INET6){address=&((struct sockaddr_in6*)it->ifa_addr)->sin6_addr;size=16;if(it->ifa_netmask)mask=&((struct sockaddr_in6*)it->ifa_netmask)->sin6_addr;}
 else return 0;
 if(!inet_ntop(family,address,out,INET6_ADDRSTRLEN))return 0;
 int prefix=0;
 if(mask){const unsigned char *bytes=mask;for(int i=0;i<size;i++){unsigned char b=bytes[i];for(int bit=7;bit>=0;bit--)if(b&(1<<bit))prefix++;}}
 else prefix=size*8;
 return prefix+1;
}
*/
import "C"

import (
	"fmt"
	"github.com/sagernet/sing-box/experimental/libbox"
)

// Use libc instead of netlink and release every getifaddrs/socket allocation.
// The selected third-party Go fork's interface enumeration lacks these releases.
func nativeInterfaces() ([]*libbox.NetworkInterface, error) {
	var all *C.struct_ifaddrs
	if C.getifaddrs(&all) != 0 {
		return nil, fmt.Errorf("getifaddrs failed")
	}
	defer C.freeifaddrs(all)
	fd := C.socket(C.AF_INET, C.SOCK_DGRAM, 0)
	if fd < 0 {
		return nil, fmt.Errorf("interface ioctl socket failed")
	}
	defer C.close(fd)
	byName := map[string]*libbox.NetworkInterface{}
	result := []*libbox.NetworkInterface{}
	for it := all; it != nil; it = it.ifa_next {
		name := C.GoString(it.ifa_name)
		item := byName[name]
		if item == nil {
			item = &libbox.NetworkInterface{Name: name, Index: int32(C.if_nametoindex(it.ifa_name)), MTU: int32(C.sb_mtu(fd, it.ifa_name)), Flags: int32(it.ifa_flags), Type: libbox.InterfaceTypeOther, Addresses: &stringIterator{}, DNSServer: &stringIterator{}, Gateway: &stringIterator{}}
			if item.Index == 0 {
				continue
			}
			byName[name] = item
			result = append(result, item)
		}
		var address [C.INET6_ADDRSTRLEN]C.char
		prefix := C.sb_address(it, &address[0])
		if prefix > 0 {
			iterator := item.Addresses.(*stringIterator)
			iterator.values = append(iterator.values, fmt.Sprintf("%s/%d", C.GoString(&address[0]), int(prefix)-1))
		}
	}
	return result, nil
}
