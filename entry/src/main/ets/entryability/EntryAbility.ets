import { UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { DIRECT_PROFILE, BLOCK_IPV6_PROFILE, initialStatus, readPrivate, writePrivate } from '../common/Store';
import { setDiagnosticProfile } from '../common/ProfileStore';
import { parseProfileImportLink } from '../common/ProfileLinks';
import { locationAssist } from '../common/LocationAssist';

export default class EntryAbility extends UIAbility {
 private diagnosticsKeepAwake: boolean = false;
 onCreate(want: Want): void {
  locationAssist.initialize(this.context);
  this.handleLink(want);
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
 onNewWant(want: Want): void {this.handleLink(want);}
 onForeground(): void {locationAssist.onForeground();}
 onBackground(): void {locationAssist.onBackground();}
 onDestroy(): void {locationAssist.stop();}
 private handleLink(want: Want): void {
  if(!want.uri){return;}
  try {AppStorage.setOrCreate('pendingRemoteProfile',JSON.stringify(parseProfileImportLink(want.uri)));} catch(_error) {}
 }
 onWindowStageCreate(stage: window.WindowStage): void {
  stage.loadContent('pages/Index');
  if(this.diagnosticsKeepAwake){stage.getMainWindow().then((main: window.Window) => {main.setWindowKeepScreenOn(true).catch(() => {});}).catch(() => {});}
 }
}
