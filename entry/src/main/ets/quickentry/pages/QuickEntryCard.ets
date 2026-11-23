import { BRAND } from '../../common/BrandTheme';

const cardStorage: LocalStorage=new LocalStorage();

@Entry(cardStorage)
@Component
struct QuickEntryCard {
 @LocalStorageProp('phase') phase: string='stopped';
 @LocalStorageProp('phaseLabel') phaseLabel: string='未连接';
 @LocalStorageProp('networkType') networkType: string='点击一键操作';
 @LocalStorageProp('active') active: boolean=false;

 private open(action: string): void {
  postCardAction(this,{action:'router',abilityName:'EntryAbility',params:{shortcutAction:action}});
 }

 private statusDotColor(): string {
  if(this.phase==='running'){return BRAND.green;}
  if(this.phase==='reconnecting' || this.phase==='paused' || this.phase==='starting'){return BRAND.amber;}
  return BRAND.muted;
 }

 build() {
  Column({space:8}) {
   // Header: Brand Icon + Title + Live Status Pill (tap to open Overview)
   Row({space:8}) {
    Image($r('app.media.app_icon')).width(30).height(30).borderRadius(9).objectFit(ImageFit.Contain)
    Column({space:1}) {
     Text('熊盒 VPN').fontSize(13).fontWeight(FontWeight.Bold).fontColor(BRAND.text).maxLines(1)
     Text(this.networkType).fontSize(10).fontColor(BRAND.muted).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    Row({space:4}) {
     Circle().width(6).height(6).fill(this.statusDotColor())
     Text(this.phaseLabel).fontSize(10).fontWeight(FontWeight.Bold).fontColor(this.phase==='running'?BRAND.green:this.active?BRAND.amber:BRAND.muted).maxLines(1)
    }.padding({left:7,right:7,top:3,bottom:3}).backgroundColor(BRAND.elevated).borderRadius(9)
   }.width('100%').onClick(() => {this.open('overview');})

   Blank()

   // Crisp Dual Pill Actions
   Row({space:8}) {
    Button(){
     Text('连接').fontSize(13).fontWeight(FontWeight.Bold).maxLines(1).fontColor(BRAND.onAccent)
    }.padding(0).layoutWeight(1).height(36).borderRadius(11).backgroundColor(BRAND.cyan).onClick(() => {this.open('connect');})
    Button(){
     Text('断开').fontSize(13).fontWeight(FontWeight.Bold).maxLines(1).fontColor(BRAND.coral)
    }.padding(0).layoutWeight(1).height(36).borderRadius(11).backgroundColor(BRAND.dangerSurface).border({width:1,color:BRAND.dangerLine}).onClick(() => {this.open('disconnect');})
   }.width('100%')
  }
  .padding(12)
  .width('100%')
  .height('100%')
  .backgroundColor(BRAND.background)
  .borderRadius(18)
  .border({width:1,color:this.phase==='running'?BRAND.cyan:BRAND.line})
 }
}
