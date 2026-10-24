//go:build openharmony

package main

/*
#cgo LDFLAGS: -lnet_connection
#include <network/netmanager/net_connection.h>
static int32_t sb_bind_socket(int32_t fd,int32_t net_id){
 NetConn_NetHandle handle={0};handle.netId=net_id;
 return OH_NetConn_BindSocket(fd,&handle);
}
*/
import "C"
import "fmt"

func bindPhysicalSocket(fd, netID int32) error {
	code := C.sb_bind_socket(C.int32_t(fd), C.int32_t(netID))
	if code != 0 {
		return fmt.Errorf("绑定物理网络失败 (code %d)", int32(code))
	}
	return nil
}
