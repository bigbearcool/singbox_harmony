import { UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { DIRECT_PROFILE, BLOCK_IPV6_PROFILE, initialStatus, readPrivate, writePrivate } from '../common/Store';
import { setDiagnosticProfile } from '../common/ProfileStore';
import { parseProfileImportLink } from '../common/ProfileLinks';
import { shortcutActionFromWant } from '../common/ShortcutActions';
import { util } from '@kit.ArkTS';
import { BRAND } from '../common/BrandTheme';
import { WindowLayout } from '../common/WindowLayout';

export default class EntryAbility extends UIAbility {
 private diagnosticsKeepAwake: boolean = false;
 private windowLayout?: WindowLayout;
 private uiAlive: boolean=true;
 onCreate(want: Want): void {
  this.handleDiagnostics(want);
  this.handleLink(want);
  this.handleShortcut(want);
  if(!this.context.applicationInfo.debug){return;}
  // Discard the staging path from the one-time USB import. The accepted copy
  // now lives in context.filesDir with mode 0600.
  try {fs.unlinkSync('/data/storage/el2/base/files/incoming-profile.json');} catch(_error) {}
  this.diagnosticsKeepAwake=want.parameters?.diagnosticsKeepAwake===true;
  const preset=want.parameters?.diagnosticsProfile;
  if(preset!=='direct' && preset!=='reject-ipv6'){return;}
  const path: string=`${this.context.filesDir}/profile.json`;
  let current: string='';
  try {current=readPrivate(path);} catch(_error) {}
  // Test startup cannot replace a user's real configuration.
  if(current!=='' && current!==DIRECT_PROFILE && current!==BLOCK_IPV6_PROFILE){return;}
  try {setDiagnosticProfile(this.context.filesDir,preset==='direct'?DIRECT_PROFILE:BLOCK_IPV6_PROFILE);} catch(_error) {return;}
  writePrivate(`${this.context.filesDir}/vpn-status.json`,JSON.stringify(initialStatus()));
 }
 onNewWant(want: Want): void {this.handleDiagnostics(want);this.handleLink(want);this.handleShortcut(want);}
 onForeground(): void {AppStorage.setOrCreate('appForeground',true);}
 onBackground(): void {AppStorage.setOrCreate('appForeground',false);}
 onDestroy(): void {this.uiAlive=false;this.windowLayout?.stop();AppStorage.setOrCreate('appForeground',false);}
 private handleDiagnostics(want: Want): void {
  const paused=want.parameters?.diagnosticsPauseForegroundUpdates;
  if(this.context.applicationInfo.debug && typeof paused==='boolean'){AppStorage.setOrCreate('diagnosticsPauseForegroundUpdates',paused);}
 }
 private handleLink(want: Want): void {
  if(!want.uri){return;}
  try {AppStorage.setOrCreate('pendingRemoteProfile',JSON.stringify(parseProfileImportLink(want.uri)));} catch(_error) {}
 }
 private handleShortcut(want: Want): void {
  const action: string=shortcutActionFromWant(want);
  if(action){AppStorage.setOrCreate('pendingShortcut',JSON.stringify({action:action,id:util.generateRandomUUID(),createdAt:Date.now()}));}
 }
 onWindowStageCreate(stage: window.WindowStage): void {
  stage.loadContent('pages/Index').then(() => stage.getMainWindow()).then((main: window.Window) => {
   if(!this.uiAlive){return;}
   try {main.setWindowBackgroundColor(BRAND.background);} catch(_error) {}
   main.setWindowLayoutFullScreen(true).then(() => {
    if(!this.uiAlive){return;}this.windowLayout=new WindowLayout();this.windowLayout.bind(main,this.context.filesDir);
   }).catch(() => {AppStorage.setOrCreate('windowLayoutReady',true);});
   main.setWindowSystemBarProperties({statusBarColor:BRAND.background,statusBarContentColor:BRAND.text,navigationBarColor:BRAND.background,navigationBarContentColor:BRAND.text}).catch(() => {});
   if(this.diagnosticsKeepAwake){main.setWindowKeepScreenOn(true).catch(() => {});}
  }).catch(() => {});
 }
}
