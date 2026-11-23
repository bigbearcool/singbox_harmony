import { BRAND } from '../common/BrandTheme';

@Component
export struct TrafficSparkline {
 @Prop @Watch('redraw') upSamples: number[] = [];
 @Prop @Watch('redraw') downSamples: number[] = [];
 private settings: RenderingContextSettings = new RenderingContextSettings(true);
 private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
 private ready: boolean = false;

 private drawSeries(samples: number[], strokeColor: string, fillColor: string, maxVal: number, w: number, h: number): void {
  if (!samples || samples.length === 0) {
   return;
  }
  const padTop: number = 6;
  const padBottom: number = 4;
  const usableH: number = Math.max(1, h - padTop - padBottom);
  const baseY: number = h - padBottom;
  const count: number = samples.length;
  const xs: number[] = [];
  const ys: number[] = [];
  const stepX: number = count > 1 ? w / (count - 1) : w;
  for (let i: number = 0; i < count; i++) {
   const raw: number = samples[i];
   const safe: number = Number.isFinite(raw) && raw > 0 ? raw : 0;
   const ratio: number = maxVal > 0 ? Math.min(1, Math.max(0, safe / maxVal)) : 0;
   xs.push(count > 1 ? i * stepX : w);
   ys.push(padTop + usableH * (1 - ratio));
  }

  // Translucent area fill underneath the curve
  this.ctx.beginPath();
  if (count === 1) {
   this.ctx.moveTo(0, baseY);
   this.ctx.lineTo(0, ys[0]);
   this.ctx.lineTo(w, ys[0]);
   this.ctx.lineTo(w, baseY);
  } else {
   this.ctx.moveTo(xs[0], baseY);
   this.ctx.lineTo(xs[0], ys[0]);
   for (let i: number = 1; i < count - 1; i++) {
    const midX: number = (xs[i] + xs[i + 1]) / 2;
    const midY: number = (ys[i] + ys[i + 1]) / 2;
    this.ctx.quadraticCurveTo(xs[i], ys[i], midX, midY);
   }
   this.ctx.lineTo(xs[count - 1], ys[count - 1]);
   this.ctx.lineTo(xs[count - 1], baseY);
  }
  this.ctx.closePath();
  this.ctx.fillStyle = fillColor;
  this.ctx.fill();

  // Smooth polyline stroke
  this.ctx.beginPath();
  if (count === 1) {
   this.ctx.moveTo(0, ys[0]);
   this.ctx.lineTo(w, ys[0]);
  } else {
   this.ctx.moveTo(xs[0], ys[0]);
   for (let i: number = 1; i < count - 1; i++) {
    const midX: number = (xs[i] + xs[i + 1]) / 2;
    const midY: number = (ys[i] + ys[i + 1]) / 2;
    this.ctx.quadraticCurveTo(xs[i], ys[i], midX, midY);
   }
   this.ctx.lineTo(xs[count - 1], ys[count - 1]);
  }
  this.ctx.strokeStyle = strokeColor;
  this.ctx.lineWidth = 1.8;
  this.ctx.lineJoin = 'round';
  this.ctx.lineCap = 'round';
  this.ctx.stroke();
 }

 private redraw(): void {
  if (!this.ready) {
   return;
  }
  const w: number = this.ctx.width;
  const h: number = this.ctx.height;
  if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) {
   return;
  }
  this.ctx.clearRect(0, 0, w, h);

  // Subtle horizontal guide lines
  this.ctx.strokeStyle = 'rgba(31, 64, 89, 0.45)';
  this.ctx.lineWidth = 1;
  const guides: number[] = [0.25, 0.5, 0.75];
  for (const ratio of guides) {
   const gy: number = Math.round(h * ratio) + 0.5;
   this.ctx.beginPath();
   this.ctx.moveTo(0, gy);
   this.ctx.lineTo(w, gy);
   this.ctx.stroke();
  }

  let maxVal: number = 0;
  for (const v of this.upSamples) {
   if (Number.isFinite(v) && v > maxVal) {
    maxVal = v;
   }
  }
  for (const v of this.downSamples) {
   if (Number.isFinite(v) && v > maxVal) {
    maxVal = v;
   }
  }
  const scaleMax: number = maxVal > 0 ? maxVal : 1;

  this.drawSeries(this.downSamples, BRAND.green, 'rgba(62, 224, 139, 0.16)', scaleMax, w, h);
  this.drawSeries(this.upSamples, BRAND.cyan, 'rgba(67, 231, 242, 0.16)', scaleMax, w, h);
 }

 build() {
  Stack({ alignContent: Alignment.TopStart }) {
   Canvas(this.ctx)
    .width('100%')
    .height(64)
    .onReady(() => {
     this.ready = true;
     this.redraw();
    })
  }
  .width('100%')
  .height(64)
  .backgroundColor(BRAND.background)
  .borderRadius(12)
  .border({ width: 1, color: BRAND.line })
  .clip(true)
 }
}
