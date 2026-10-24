import { UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { DIRECT_PROFILE, BLOCK_IPV6_PROFILE, initialStatus, readPrivate, writePrivate } from '../common/Store';

export default class EntryAbility extends UIAbility {
 private diagnosticsKeepAwake: boolean = false;
 onCreate(want: Want): void {
  if(!this.context.applicationInfo.debug){return;}
  this.diagnosticsKeepAwake=want.parameters?.diagnosticsKeepAwake===true;
  const preset=want.parameters?.diagnosticsProfile;
  if(preset!=='direct' && preset!=='reject-ipv6'){return;}
  const path: string=`${this.context.filesDir}/profile.json`;
  let current: string='';
  try {current=readPrivate(path);} catch(_error) {}
  // Test startup cannot replace a user's real configuration.
  if(current!=='' && current!==DIRECT_PROFILE && current!==BLOCK_IPV6_PROFILE){return;}
  writePrivate(path,preset==='direct'?DIRECT_PROFILE:BLOCK_IPV6_PROFILE);
  writePrivate(`${this.context.filesDir}/vpn-status.json`,JSON.stringify(initialStatus()));
 }
 onWindowStageCreate(stage: window.WindowStage): void {
  stage.loadContent('pages/Index');
  if(this.diagnosticsKeepAwake){stage.getMainWindow().then((main: window.Window) => {main.setWindowKeepScreenOn(true).catch(() => {});}).catch(() => {});}
 }
}
