import { socket, connection } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import bridge from 'libsingboxbridge.so';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

function tcpProbe(ipv6: boolean,netId: number): Promise<boolean> {
 return new Promise<boolean>((resolve) => {
  const client: socket.TCPSocket=socket.constructTCPSocketInstance();
  let finished: boolean=false;
  let timer: number=-1;
  let received: string='';
  let stage: string='bind-local';
  const finish=(ok: boolean): void => {
   if(finished){return;}finished=true;
   if(timer!==-1){clearTimeout(timer);}
   client.off('message');client.off('error');
   client.close().catch(() => {});resolve(ok);
  };
  client.on('message',(info: socket.SocketMessageInfo) => {
   received+=util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(info.message));
   if(received.length>=12){finish(/^HTTP\/1\.[01] [0-9]{3}/.test(received));}
  });
  client.on('error',() => {finish(false);});
  timer=setTimeout(() => {hilog.warn(0x1700,'SingboxHarmony','tcp%{public}d timeout at %{public}s',ipv6?6:4,stage);finish(false);},6000);
  const run=async (): Promise<void> => {
   await client.bind({address:ipv6?'::':'0.0.0.0',family:ipv6?2:1,port:0});
   stage='bind-vpn';
   bridge.bindSocket(await client.getSocketFd(),netId);
   stage='connect';
   await client.connect({address:{address:ipv6?'2400:3200::1':'223.5.5.5',family:ipv6?2:1,port:80},timeout:5000});
   stage='http-response';
   await client.send({data:'HEAD / HTTP/1.1\r\nHost: dns.alidns.com\r\nConnection: close\r\n\r\n'});
  };
  run().catch((error: BusinessError) => {hilog.warn(0x1700,'SingboxHarmony','tcp%{public}d failed at %{public}s: %{public}s',ipv6?6:4,stage,error.message);finish(false);});
 });
}

function dnsProbe(ipv6: boolean,netId: number,virtualServer: boolean=false): Promise<boolean> {
 return new Promise<boolean>((resolve) => {
  const client: socket.UDPSocket=socket.constructUDPSocketInstance();
  let finished: boolean=false;
  let timer: number=-1;
  let stage: string='bind-local';
  const finish=(ok: boolean): void => {
   if(finished){return;}finished=true;
   if(timer!==-1){clearTimeout(timer);}
   client.off('message');client.off('error');
   client.close().catch(() => {});resolve(ok);
  };
  const transaction: number=ipv6?0x1211:0x1210;
  // one.one.one.one; A over IPv4 and AAAA over IPv6 to the virtual TUN DNS.
  const request: Uint8Array=new Uint8Array([0x12,ipv6?0x11:0x10,1,0,0,1,0,0,0,0,0,0,3,111,110,101,3,111,110,101,3,111,110,101,3,111,110,101,0,0,ipv6?28:1,0,1]);
  client.on('message',(info: socket.SocketMessageInfo) => {
   const bytes: Uint8Array=new Uint8Array(info.message);
   if(bytes.length<12 || ((bytes[0]<<8)|bytes[1])!==transaction){return;}
   finish((bytes[2]&0x80)!==0 && (bytes[3]&0x0f)===0 && ((bytes[6]<<8)|bytes[7])>0);
  });
  client.on('error',() => {finish(false);});
  timer=setTimeout(() => {hilog.warn(0x1700,'SingboxHarmony','dns%{public}d timeout at %{public}s',ipv6?6:4,stage);finish(false);},6000);
  const run=async (): Promise<void> => {
   await client.bind({address:ipv6?'::':'0.0.0.0',family:ipv6?2:1,port:0});
   stage='bind-vpn';
   bridge.bindSocket(await client.getSocketFd(),netId);
   stage='send';
   // Documentation-only addresses have no upstream DNS server. A response can
   // only come from the VPN's port-53 interception, via its default routes.
   const destination: string=virtualServer?(ipv6?'fdfe:dcba:9876::2':'172.19.0.2'):(ipv6?'2001:db8::53':'192.0.2.53');
   await client.send({data:request.buffer as ArrayBuffer,address:{address:destination,family:ipv6?2:1,port:53}});
   stage='response';
  };
  run().catch((error: BusinessError) => {hilog.warn(0x1700,'SingboxHarmony','dns%{public}d failed at %{public}s: %{public}s',ipv6?6:4,stage,error.message);finish(false);});
 });
}

export async function runNetworkProbes(): Promise<string> {
 // The VPN app's own processes can be exempt from automatic VPN routing. Bind
 // test sockets to the actual VPN network so a successful probe proves its path.
 let vpnNetId: number=0;
 for(const net of await connection.getAllNets()) {
  const caps: connection.NetCapabilities=await connection.getNetCapabilities(net);
  if(!caps.bearerTypes.includes(connection.NetBearType.BEARER_VPN)){continue;}
  const properties: connection.ConnectionProperties=await connection.getConnectionProperties(net);
  if(properties.linkAddresses.some((it: connection.LinkAddress): boolean => it.address.address==='172.19.0.1')){
   hilog.info(0x1700,'SingboxHarmony','vpnLink v4=%{public}s v6=%{public}s routes=%{public}s',String(properties.isIPv4LinkValid),String(properties.isIPv6LinkValid),JSON.stringify(properties.routes));
   vpnNetId=net.netId;break;
  }
 }
 if(vpnNetId===0){return '未发现可供检查的系统 VPN 网络';}
 const checked: boolean[]=await Promise.all([tcpProbe(false,vpnNetId),tcpProbe(true,vpnNetId),dnsProbe(false,vpnNetId),dnsProbe(true,vpnNetId),dnsProbe(false,vpnNetId,true),dnsProbe(true,vpnNetId,true)]);
 const results: boolean[]=[checked[0],checked[1],checked[2] && checked[4],checked[3] && checked[5]];
 const labels: string[]=['IPv4 网页','IPv6 网页','IPv4 DNS A','IPv6 DNS AAAA'];
 return results.map((ok: boolean,index: number): string => `${labels[index]}：${ok?'成功':'未通过'}`).join('\n');
}
