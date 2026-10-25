import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { SUBSCRIPTION_WORK_ID, SUBSCRIPTION_WORK_ABILITY } from '../common/SubscriptionSchedule';
import { ProfileFetchCancellation, loadLibrary } from '../common/ProfileStore';
import { runDueProfileUpdates, profileUpdateDue } from '../common/SubscriptionUpdates';
import { BUNDLE_NAME, writePrivate } from '../common/Store';

interface WorkDiagnostic {receivedAt: number; workId: number; ownBundle: boolean; ownAbility: boolean; profiles: number; due: number;}

export default class SubscriptionWorkAbility extends WorkSchedulerExtensionAbility {
 private cancellation?: ProfileFetchCancellation;
 onWorkStart(work: workScheduler.WorkInfo): void {
  try {
   const library=loadLibrary(this.context.filesDir);
   const diagnostic: WorkDiagnostic={receivedAt:Date.now(),workId:work.workId,ownBundle:work.bundleName===BUNDLE_NAME,ownAbility:work.abilityName===SUBSCRIPTION_WORK_ABILITY,profiles:library.profiles.length,due:library.profiles.filter((profile) => profileUpdateDue(profile,Date.now())).length};
   writePrivate(`${this.context.filesDir}/subscription-work-debug.json`,JSON.stringify(diagnostic));
  } catch(_error) {}
  if(work.workId!==SUBSCRIPTION_WORK_ID || work.bundleName!==BUNDLE_NAME || work.abilityName!==SUBSCRIPTION_WORK_ABILITY || this.cancellation){return;}
  const cancellation: ProfileFetchCancellation=new ProfileFetchCancellation();this.cancellation=cancellation;
  runDueProfileUpdates(this.context.filesDir,'background',cancellation,100000).finally(() => {
   if(this.cancellation!==cancellation){return;}this.cancellation=undefined;
   // End this execution, preserve the repeating registration.
   try {workScheduler.stopWork(work,false);} catch(_error) {}
  });
 }
 onWorkStop(work: workScheduler.WorkInfo): void {
  if(work.workId===SUBSCRIPTION_WORK_ID){this.cancellation?.cancel();}
 }
}
