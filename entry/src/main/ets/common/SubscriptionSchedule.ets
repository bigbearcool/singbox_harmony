import { workScheduler } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { loadLibrary, loadSettings, SavedProfile } from './ProfileStore';
import { BUNDLE_NAME, readPrivate, writePrivate } from './Store';

export const SUBSCRIPTION_WORK_ID: number=17001;
export const SUBSCRIPTION_WORK_ABILITY: string='SubscriptionWorkAbility';
export interface ScheduleStatus {updatedAt: number; registered: boolean; intervalHours: number; message: string;}
export function readScheduleStatus(dir: string): ScheduleStatus {
 try {return JSON.parse(readPrivate(`${dir}/subscription-schedule.json`)) as ScheduleStatus;} catch(_error) {return {updatedAt:0,registered:false,intervalHours:0,message:'尚未核对系统后台更新任务'};}
}
let scheduling: Promise<ScheduleStatus>=Promise.resolve<ScheduleStatus>({updatedAt:0,registered:false,intervalHours:0,message:''});
export function syncSubscriptionSchedule(dir: string): Promise<ScheduleStatus> {
 scheduling=scheduling.then(async (): Promise<ScheduleStatus> => {
  const status: ScheduleStatus={updatedAt:Date.now(),registered:false,intervalHours:0,message:''};
  try {
   const profiles=loadLibrary(dir).profiles.filter((profile: SavedProfile): boolean => !!profile.url && Number.isFinite(profile.autoUpdateHours) && profile.autoUpdateHours>0);
   const enabled: boolean=loadSettings(dir).backgroundUpdates && profiles.length>0;
   // Use a conservative public scheduling interval. It is a request, never a
   // promise of execution at a particular wall-clock time.
   status.intervalHours=enabled?Math.max(2,Math.min(...profiles.map((profile: SavedProfile): number => profile.autoUpdateHours))):0;
   const works=await workScheduler.obtainAllWorks();
   const current: workScheduler.WorkInfo | undefined=works.find((work: workScheduler.WorkInfo): boolean => work.workId===SUBSCRIPTION_WORK_ID && work.bundleName===BUNDLE_NAME && work.abilityName===SUBSCRIPTION_WORK_ABILITY);
   if(current && (!enabled || current.repeatCycleTime!==status.intervalHours*3600000 || current.isPersisted!==true || current.isRepeat!==true || current.networkType!==workScheduler.NetworkType.NETWORK_TYPE_ANY)){workScheduler.stopWork(current,true);}
   if(enabled){
    if(!current || current.repeatCycleTime!==status.intervalHours*3600000 || current.isPersisted!==true || current.isRepeat!==true || current.networkType!==workScheduler.NetworkType.NETWORK_TYPE_ANY){
     workScheduler.startWork({workId:SUBSCRIPTION_WORK_ID,bundleName:BUNDLE_NAME,abilityName:SUBSCRIPTION_WORK_ABILITY,isPersisted:true,isRepeat:true,repeatCycleTime:status.intervalHours*3600000,networkType:workScheduler.NetworkType.NETWORK_TYPE_ANY});
    }
    status.registered=true;status.message='已登记系统后台更新，系统有网时择机执行';
   } else {status.message=profiles.length===0?'没有启用自动更新的远程配置':'系统后台更新已关闭，前台仍可检查';}
  } catch(error) {status.message=`后台更新登记未完成（${(error as BusinessError).code || 0}），前台仍可更新`;}
  status.updatedAt=Date.now();try {writePrivate(`${dir}/subscription-schedule.json`,JSON.stringify(status));} catch(_error) {}
  return status;
 });
 return scheduling;
}
