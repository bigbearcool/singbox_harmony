export interface RemoteProfileDraft {name: string; url: string;}

function validRemoteURL(value: string): boolean {
 return value.length>0 && value.length<=8192 && /^https?:\/\/[^/?#\s\\]+(?:[/?#][^\s\\]*)?$/i.test(value);
}
export function profileImportLink(name: string,remoteURL: string): string {
 if(!validRemoteURL(remoteURL)){throw new Error('配置链接无效');}
 // Matches libbox.GenerateRemoteProfileImportLink: name is a URL fragment.
 return `sing-box://import-remote-profile?url=${encodeURIComponent(remoteURL)}#${encodeURIComponent(name)}`;
}
export function parseProfileImportLink(input: string): RemoteProfileDraft {
 const value: string=input.trim();
 if(validRemoteURL(value)){return {name:'远程配置',url:value};}
 if(value.length>24576 || !/^sing-box:\/\/import-remote-profile\/?\?/i.test(value)){throw new Error('不是 sing-box 配置链接');}
 const hash: number=value.indexOf('#');
 const query: string=value.slice(value.indexOf('?')+1,hash<0?value.length:hash);
 let remote: string='';let count: number=0;
 try {
  for(const part of query.split('&')){
   const equals: number=part.indexOf('=');
   const key: string=decodeURIComponent((equals<0?part:part.slice(0,equals)).replace(/\+/g,' '));
   if(key==='url'){count++;remote=decodeURIComponent((equals<0?'':part.slice(equals+1)).replace(/\+/g,' '));}
  }
  const name: string=hash<0?'远程配置':decodeURIComponent(value.slice(hash+1));
  if(count!==1 || !validRemoteURL(remote)){throw new Error('配置链接无效');}
  return {name:name.slice(0,80) || '远程配置',url:remote};
 } catch(_error) {throw new Error('配置链接格式无效');}
}
