import { BRAND } from '../../common/BrandTheme';

@Entry
@Component
struct QuickEntryCard {
 private open(action: string): void {
  postCardAction(this,{action:'router',abilityName:'EntryAbility',params:{shortcutAction:action}});
 }
 build() {
  Column({space:7}) {
   Row({space:7}) {
    Image($r('app.media.app_icon')).width(28).height(28).borderRadius(8)
    Text('熊盒 VPN').fontSize(14).fontWeight(FontWeight.Bold).fontColor(BRAND.text).maxLines(1).layoutWeight(1)
   }.width('100%').onClick(() => {this.open('overview');})
   Text('点击打开并执行').fontSize(11).fontColor(BRAND.muted).width('100%')
   Blank()
   Row({space:8}) {
    Button(){Text('连接').fontSize(14).maxLines(1).fontColor(BRAND.onAccent)}.padding(0).layoutWeight(1).height(36).backgroundColor(BRAND.cyan).onClick(() => {this.open('connect');})
    Button(){Text('断开').fontSize(14).maxLines(1).fontColor(BRAND.coral)}.padding(0).layoutWeight(1).height(36).backgroundColor(BRAND.dangerSurface).onClick(() => {this.open('disconnect');})
   }.width('100%')
   Text('打开总览 ›').fontSize(11).fontColor(BRAND.cyan).width('100%').onClick(() => {this.open('overview');})
  }.padding(12).width('100%').height('100%').backgroundColor(BRAND.background).border({width:1,color:BRAND.line})
 }
}
