import { window } from '@kit.ArkUI';
import { writePrivate } from './Store';

// Full-window background, system-measured padding for interactive content.
// Re-read on fold/resize and when the status/gesture/cutout regions change.
export class WindowLayout {
 private main?: window.Window;
 private dir: string='';
 private avoidChanged=(_event: window.AvoidAreaOptions): void => {this.update();};
 private resized=(_size: window.Size): void => {this.update();};
 bind(main: window.Window,dir: string): void {
  this.stop();this.main=main;this.dir=dir;
  try {main.on('avoidAreaChange',this.avoidChanged);} catch(_error) {}
  try {main.on('windowSizeChange',this.resized);} catch(_error) {}
  this.update();
 }
 private update(): void {
  if(!this.main){return;}
  try {
   const main=this.main;const ui=main.getUIContext();
   const system=main.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
   const indicator=main.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
   const cutout=main.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
   const top: number=ui.px2vp(Math.max(system.topRect.height,cutout.topRect.height));
   const bottom: number=ui.px2vp(Math.max(system.bottomRect.height,indicator.bottomRect.height,cutout.bottomRect.height));
   const left: number=ui.px2vp(Math.max(system.leftRect.width,cutout.leftRect.width));
   const right: number=ui.px2vp(Math.max(system.rightRect.width,cutout.rightRect.width));
   AppStorage.setOrCreate('windowSafeTop',top);AppStorage.setOrCreate('windowSafeBottom',bottom);
   AppStorage.setOrCreate('windowSafeLeft',left);AppStorage.setOrCreate('windowSafeRight',right);
   const rect=main.getWindowProperties().windowRect;
   try {writePrivate(`${this.dir}/window-layout.json`,JSON.stringify({updatedAt:Date.now(),width:rect.width,height:rect.height,top:top,bottom:bottom,left:left,right:right}));} catch(_error) {}
  } catch(_error) {}
  AppStorage.setOrCreate('windowLayoutReady',true);
 }
 stop(): void {
  if(this.main){
   try {this.main.off('avoidAreaChange',this.avoidChanged);} catch(_error) {}
   try {this.main.off('windowSizeChange',this.resized);} catch(_error) {}
  }
  this.main=undefined;
 }
}
