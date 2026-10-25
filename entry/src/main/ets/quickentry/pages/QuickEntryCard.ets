@Entry
@Component
struct QuickEntryCard {
 private open(action: string): void {
  postCardAction(this,{action:'router',abilityName:'EntryAbility',params:{shortcutAction:action}});
 }
 build() {
  Column({space:8}) {
   Text('熊盒 VPN').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#18334A').width('100%').onClick(() => {this.open('overview');})
   Text('点击打开并执行').fontSize(12).fontColor('#607286').width('100%')
   Blank()
   Row({space:8}) {
    Button(){Text('连接').fontSize(14).maxLines(1).fontColor('#FFFFFF')}.padding(0).layoutWeight(1).height(36).backgroundColor('#176B59').onClick(() => {this.open('connect');})
    Button(){Text('断开').fontSize(14).maxLines(1).fontColor('#18334A')}.padding(0).layoutWeight(1).height(36).backgroundColor('#E3EAF0').onClick(() => {this.open('disconnect');})
   }.width('100%')
   Text('打开总览 ›').fontSize(12).fontColor('#176B59').width('100%').onClick(() => {this.open('overview');})
  }.padding(14).width('100%').height('100%').backgroundColor('#F3F7F9')
 }
}
