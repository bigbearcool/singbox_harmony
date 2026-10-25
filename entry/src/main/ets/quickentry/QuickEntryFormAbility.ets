import { FormExtensionAbility, formBindingData } from '@kit.FormKit';

// A launcher only: no config, network names, credentials or cached VPN status
// are sent to the desktop. VPN operations remain in the foreground UIAbility.
export default class QuickEntryFormAbility extends FormExtensionAbility {
 onAddForm(): formBindingData.FormBindingData {return formBindingData.createFormBindingData({});}
}
