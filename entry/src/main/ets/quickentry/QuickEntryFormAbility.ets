import { Want } from '@kit.AbilityKit';
import { FormExtensionAbility, formBindingData, formInfo } from '@kit.FormKit';
import { readCurrentCardState, registerFormId, unregisterFormId } from '../common/FormSync';

// Event-driven status sync only: no config, SSID, credentials or URLs are ever
// sent to the desktop card. VPN operations remain in the foreground UIAbility.
export default class QuickEntryFormAbility extends FormExtensionAbility {
 onAddForm(want: Want): formBindingData.FormBindingData {
  const rawId: Object | undefined=want.parameters?.[formInfo.FormParam.IDENTITY_KEY];
  if(typeof rawId==='string' && rawId.length>0){
   registerFormId(this.context.filesDir,rawId);
  }
  return formBindingData.createFormBindingData(readCurrentCardState(this.context.filesDir));
 }
 onRemoveForm(formId: string): void {
  unregisterFormId(this.context.filesDir,formId);
 }
}
