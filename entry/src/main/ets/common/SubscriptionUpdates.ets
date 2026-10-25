import { fileIo as fs } from '@kit.CoreFileKit';
import bridge from 'libsingboxbridge.so';
import { loadLibrary, loadSettings, SavedProfile, refreshProfile, ProfileFetchCancellation } from './ProfileStore';
import { readPrivate, writePrivate } from './Store';

export interface UpdateAttempt {id: string; revision: string; profileUpdatedAt: number; intervalHours: number; attemptedAt: number; nextRetryAt: number; failures: number; outcome: string;}
export interface UpdateReport {updatedAt: number; source: string; phase: string; updated: number; failed: number; skipped: number; attempts: UpdateAttempt[];}
function emptyReport(): UpdateReport {return {updatedAt:0,source:'',phase:'idle',updated:0,failed:0,skipped:0,attempts:[]};}
export function readUpdateReport(dir: string): UpdateReport {
 try {const report=JSON.parse(readPrivate(`${dir}/subscription-updates.json`)) as UpdateReport;if(Array.isArray(report.attempts)){report.attempts=report.attempts.filter((attempt: UpdateAttempt): boolean => typeof attempt.id==='string' && typeof attempt.revision==='string' && Number.isFinite(attempt.profileUpdatedAt) && Number.isFinite(attempt.nextRetryAt) && Number.isFinite(attempt.failures));return report;}} catch(_error) {}
 return emptyReport();
}
export function profileUpdateDue(profile: SavedProfile,now: number): boolean {
 return !!profile.url && Number.isFinite(profile.autoUpdateHours) && profile.autoUpdateHours>0 && now-profile.updatedAt>=profile.autoUpdateHours*3600000;
}
function sameRevision(attempt: UpdateAttempt,profile: SavedProfile): boolean {
 return attempt.revision===(profile.revision || '') && attempt.profileUpdatedAt===profile.updatedAt && attempt.intervalHours===profile.autoUpdateHours;
}
export function updateRetryDue(attempt: UpdateAttempt | undefined,profile: SavedProfile,now: number): boolean {
 return !attempt || !sameRevision(attempt,profile) || attempt.nextRetryAt<=now;
}
// One lease across UI and WorkScheduler processes; the profile-index lock is
// deliberately not held while downloading. A process death releases this lock.
export async function runDueProfileUpdates(dir: string,source: string,cancellation: ProfileFetchCancellation,budgetMs: number=100000): Promise<UpdateReport> {
 const report: UpdateReport={updatedAt:Date.now(),source:source,phase:'running',updated:0,failed:0,skipped:0,attempts:[]};
 let lease: fs.File | undefined;let locked: boolean=false;let timer: number=-1;
 const deadline: number=Date.now()+Math.min(100000,Math.max(1000,budgetMs));
 try {
  lease=fs.openSync(`${dir}/subscription-updates.lock`,fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);bridge.secureFile(lease.fd);
  try {lease.tryLock(true);locked=true;} catch(_error) {report.phase='busy';return report;}
  const library=loadLibrary(dir);const ids: string[]=library.profiles.map((profile: SavedProfile): string => profile.id);
  report.attempts=readUpdateReport(dir).attempts.filter((attempt: UpdateAttempt): boolean => ids.includes(attempt.id));
  const allowed=(): boolean => !cancellation.cancelled && Date.now()<deadline && (source!=='background' || loadSettings(dir).backgroundUpdates);
  if(!allowed()){report.phase='disabled';return report;}
  timer=setTimeout(() => {cancellation.cancel();},Math.max(1,deadline-Date.now()));
  writePrivate(`${dir}/subscription-updates.json`,JSON.stringify(report));
  const candidates: SavedProfile[]=library.profiles.filter((profile: SavedProfile): boolean => profileUpdateDue(profile,Date.now())).sort((a: SavedProfile,b: SavedProfile): number => a.updatedAt-b.updatedAt);
  for(const candidate of candidates){
   if(!allowed()){break;}
   if(deadline-Date.now()<30000){report.skipped++;break;}
   const current=loadLibrary(dir);const profile: SavedProfile | undefined=current.profiles.find((item: SavedProfile): boolean => item.id===candidate.id);
   if(!profile || !profileUpdateDue(profile,Date.now())){report.skipped++;continue;}
   const previous: UpdateAttempt | undefined=report.attempts.find((attempt: UpdateAttempt): boolean => attempt.id===profile.id);
   if(!updateRetryDue(previous,profile,Date.now())){report.skipped++;continue;}
   const attempt: UpdateAttempt={id:profile.id,revision:profile.revision || '',profileUpdatedAt:profile.updatedAt,intervalHours:profile.autoUpdateHours,attemptedAt:Date.now(),nextRetryAt:0,failures:0,outcome:'updated'};
   try {
    await refreshProfile(dir,current,profile.id,allowed,cancellation,true);report.updated++;
   } catch(_error) {
    if(!allowed()){report.phase='cancelled';break;}
    // A concurrent edit/deletion wins; do not treat it as a server failure or
    // replace its new revision with the result of an earlier download.
    const latest=loadLibrary(dir).profiles.find((item: SavedProfile): boolean => item.id===profile.id);
    if(!latest || latest.revision!==profile.revision || latest.updatedAt!==profile.updatedAt || latest.autoUpdateHours!==profile.autoUpdateHours){report.skipped++;continue;}
    attempt.outcome='failed';attempt.failures=previous && sameRevision(previous,profile)?Math.min(previous.failures+1,6):1;
    attempt.nextRetryAt=Date.now()+Math.min(6*3600000,15*60000*Math.pow(2,attempt.failures-1));report.failed++;
   }
   report.attempts=report.attempts.filter((item: UpdateAttempt): boolean => item.id!==profile.id);report.attempts.push(attempt);
   report.updatedAt=Date.now();writePrivate(`${dir}/subscription-updates.json`,JSON.stringify(report));
  }
  report.phase=allowed()?'completed':'cancelled';return report;
 } catch(_error) {report.phase=cancellation.cancelled?'cancelled':'error';return report;}
 finally {
  if(timer!==-1){clearTimeout(timer);}
  if(locked){
   report.updatedAt=Date.now();
   try {writePrivate(`${dir}/subscription-updates.json`,JSON.stringify(report));} catch(_error) {}
   try {lease?.unlock();} catch(_error) {}
  }
  if(lease){try {fs.closeSync(lease);} catch(_error) {}}
 }
}
