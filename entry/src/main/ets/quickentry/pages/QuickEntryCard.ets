import { BRAND } from '../../common/BrandTheme';

const cardStorage: LocalStorage=new LocalStorage();

@Entry(cardStorage)
@Component
struct QuickEntryCard {
 @LocalStorageProp('phase') phase: string = 'stopped';
 @LocalStorageProp('phaseLabel') phaseLabel: string = '未连接';
 @LocalStorageProp('networkType') networkType: string = '点击一键操作';
 @LocalStorageProp('active') active: boolean = false;
 @LocalStorageProp('mode') mode: string = '';
 @LocalStorageProp('trafficLabel') trafficLabel: string = '';
 @LocalStorageProp('isWide') isWide: boolean = false;
 @State private wideLayout: boolean = false;
 @State private measured: boolean = false;

 private open(action: string): void {
  postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { shortcutAction: action } });
 }

 private statusDotColor(): string {
  if (this.phase === 'running') { return BRAND.green; }
  if (this.phase === 'reconnecting' || this.phase === 'paused' || this.phase === 'starting') { return BRAND.amber; }
  return BRAND.muted;
 }

 private statusTextColor(): string {
  if (this.phase === 'running') { return BRAND.green; }
  if (this.active) { return BRAND.amber; }
  return BRAND.muted;
 }

 private useWideLayout(): boolean {
  return this.measured ? this.wideLayout : this.isWide;
 }

 private wideSubtitle(): string {
  const parts: string[] = [];
  if (this.networkType) { parts.push(this.networkType); }
  if (this.mode) { parts.push(this.mode); }
  if (this.trafficLabel) { parts.push(this.trafficLabel); }
  return parts.length > 0 ? parts.join(' · ') : '点击一键操作';
 }

 build() {
  Column() {
   if (this.useWideLayout()) {
    // 2×4 Wide Console Layout: Surge-style 2-column horizontal control bar
    Row({ space: 12 }) {
     // Left Column: Brand + Live Glowing Status Pill + Network/Mode/Traffic Subtitle
     Column({ space: 8 }) {
      Row({ space: 10 }) {
       Image($r('app.media.app_icon'))
        .width(36)
        .height(36)
        .borderRadius(10)
        .objectFit(ImageFit.Contain)
       Column({ space: 4 }) {
        Text('熊盒 VPN')
         .fontSize(14)
         .fontWeight(FontWeight.Bold)
         .fontColor(BRAND.text)
         .maxLines(1)
        Row({ space: 5 }) {
         Circle()
          .width(6)
          .height(6)
          .fill(this.statusDotColor())
         Text(this.phaseLabel)
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.statusTextColor())
          .maxLines(1)
        }
        .padding({ left: 7, right: 7, top: 2, bottom: 2 })
        .backgroundColor(BRAND.elevated)
        .borderRadius(9)
        .border({ width: 1, color: this.phase === 'running' ? BRAND.green : BRAND.line })
       }
       .alignItems(HorizontalAlign.Start)
       .layoutWeight(1)
      }
      .width('100%')

      Blank()

      Text(this.wideSubtitle())
       .fontSize(11)
       .fontColor(BRAND.muted)
       .maxLines(1)
       .textOverflow({ overflow: TextOverflow.Ellipsis })
       .width('100%')
     }
     .alignItems(HorizontalAlign.Start)
     .layoutWeight(1)
     .height('100%')
     .onClick(() => { this.open('overview'); })

     // Right Column: 2×2 Crisp Action Grid
     Column({ space: 6 }) {
      Row({ space: 6 }) {
       Button() {
        Text('连接').fontSize(12).fontWeight(FontWeight.Bold).maxLines(1).fontColor(BRAND.onAccent)
       }
       .padding(0)
       .layoutWeight(1)
       .height(34)
       .borderRadius(10)
       .backgroundColor(BRAND.cyan)
       .onClick(() => { this.open('connect'); })

       Button() {
        Text('断开').fontSize(12).fontWeight(FontWeight.Bold).maxLines(1).fontColor(BRAND.coral)
       }
       .padding(0)
       .layoutWeight(1)
       .height(34)
       .borderRadius(10)
       .backgroundColor(BRAND.dangerSurface)
       .border({ width: 1, color: BRAND.dangerLine })
       .onClick(() => { this.open('disconnect'); })
      }
      .width('100%')

      Row({ space: 6 }) {
       Button() {
        Text('重连').fontSize(12).fontWeight(FontWeight.Bold).maxLines(1).fontColor(BRAND.cyan)
       }
       .padding(0)
       .layoutWeight(1)
       .height(34)
       .borderRadius(10)
       .backgroundColor(BRAND.soft)
       .border({ width: 1, color: BRAND.line })
       .onClick(() => { this.open('reconnect'); })

       Button() {
        Text('总览').fontSize(12).fontWeight(FontWeight.Bold).maxLines(1).fontColor(BRAND.cyan)
       }
       .padding(0)
       .layoutWeight(1)
       .height(34)
       .borderRadius(10)
       .backgroundColor(BRAND.soft)
       .border({ width: 1, color: BRAND.line })
       .onClick(() => { this.open('overview'); })
      }
      .width('100%')
     }
     .width(136)
     .justifyContent(FlexAlign.Center)
     .height('100%')
    }
    .width('100%')
    .height('100%')
   } else {
    // 2×2 Compact Vertical Obsidian-Navy Card
    Column({ space: 8 }) {
     // Header: Brand Icon + Title + Live Status Pill (tap to open Overview)
     Row({ space: 8 }) {
      Image($r('app.media.app_icon')).width(30).height(30).borderRadius(9).objectFit(ImageFit.Contain)
      Column({ space: 1 }) {
       Text('熊盒 VPN').fontSize(13).fontWeight(FontWeight.Bold).fontColor(BRAND.text).maxLines(1)
       Text(this.networkType).fontSize(10).fontColor(BRAND.muted).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Row({ space: 4 }) {
       Circle().width(6).height(6).fill(this.statusDotColor())
       Text(this.phaseLabel).fontSize(10).fontWeight(FontWeight.Bold).fontColor(this.statusTextColor()).maxLines(1)
      }.padding({ left: 7, right: 7, top: 3, bottom: 3 }).backgroundColor(BRAND.elevated).borderRadius(9)
     }.width('100%').onClick(() => { this.open('overview'); })

     Blank()

     // Crisp Dual Pill Actions
     Row({ space: 8 }) {
      Button() {
       Text('连接').fontSize(13).fontWeight(FontWeight.Bold).maxLines(1).fontColor(BRAND.onAccent)
      }.padding(0).layoutWeight(1).height(36).borderRadius(11).backgroundColor(BRAND.cyan).onClick(() => { this.open('connect'); })
      Button() {
       Text('断开').fontSize(13).fontWeight(FontWeight.Bold).maxLines(1).fontColor(BRAND.coral)
      }.padding(0).layoutWeight(1).height(36).borderRadius(11).backgroundColor(BRAND.dangerSurface).border({ width: 1, color: BRAND.dangerLine }).onClick(() => { this.open('disconnect'); })
     }.width('100%')
    }
    .width('100%')
    .height('100%')
   }
  }
  .padding(12)
  .width('100%')
  .height('100%')
  .backgroundColor(BRAND.background)
  .borderRadius(18)
  .border({ width: 1, color: this.phase === 'running' ? BRAND.cyan : BRAND.line })
  .onAreaChange((_oldVal: Area, newVal: Area) => {
   const w: number = Number(newVal.width);
   if (Number.isFinite(w) && w > 0) {
    this.wideLayout = w >= 220;
    this.measured = true;
   }
  })
 }
}
