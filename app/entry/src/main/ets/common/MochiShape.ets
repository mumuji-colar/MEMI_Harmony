import { PathShape } from '@kit.ArkUI';

/**
 * G2 连续曲率圆角。
 *
 * ArkUI 的 borderRadius 只能画四分之一圆，这里用超椭圆角（|x|^n + |y|^n = 1，n = 4）
 * 采样成路径：曲线在直边端点处曲率趋近 0，和直边拼接时曲率连续，也就是 mochi 用的 G2。
 * 半径超过短边一半时自动退化成胶囊。
 *
 * 路径命令单位是 px，所以调用方要先把 vp 换成 px。
 */

const CORNER_STEPS: number = 10;
const EXPONENT: number = 4;

function px(value: number): number {
  return vp2px(value);
}

function nf(v: number): string {
  // 路径里不保留过多小数，减少字符串长度
  return (Math.round(v * 100) / 100).toString();
}

function cornerPoints(cx: number, cy: number, r: number, quadrant: number): number[][] {
  const out: number[][] = [];
  const n = EXPONENT;
  for (let i = 0; i <= CORNER_STEPS; i++) {
    const t = (Math.PI / 2) * (i / CORNER_STEPS);
    // |cos|^(2/n) / |sin|^(2/n)，n=4 时两端曲率为 0
    const c = Math.pow(Math.cos(t), 2 / n);
    const s = Math.pow(Math.sin(t), 2 / n);
    let dx = 0;
    let dy = 0;
    if (quadrant === 0) {
      // 左上：(-r,0) → (0,-r)
      dx = -r * c;
      dy = -r * s;
    } else if (quadrant === 1) {
      // 右上：(0,-r) → (r,0)
      dx = r * s;
      dy = -r * c;
    } else if (quadrant === 2) {
      // 右下：(r,0) → (0,r)
      dx = r * c;
      dy = r * s;
    } else {
      // 左下：(0,r) → (-r,0)
      dx = -r * s;
      dy = r * c;
    }
    out.push([cx + dx, cy + dy]);
  }
  return out;
}

/** 生成一个连续曲率圆角矩形的 SVG 路径命令（px） */
export function mochiRectCommands(widthPx: number, heightPx: number, radiusPx: number): string {
  const w = Math.max(1, widthPx);
  const h = Math.max(1, heightPx);
  const r = Math.max(0, Math.min(radiusPx, Math.min(w, h) / 2));
  if (r < 0.5) {
    return `M0 0 L${nf(w)} 0 L${nf(w)} ${nf(h)} L0 ${nf(h)} Z`;
  }

  const parts: string[] = [];
  parts.push(`M${nf(r)} 0`);
  parts.push(`L${nf(w - r)} 0`);

  // 右上
  const tr = cornerPoints(w - r, r, r, 1);
  for (let i = 0; i < tr.length; i++) {
    parts.push(`L${nf(tr[i][0])} ${nf(tr[i][1])}`);
  }
  parts.push(`L${nf(w)} ${nf(h - r)}`);

  // 右下
  const br = cornerPoints(w - r, h - r, r, 2);
  for (let i = 0; i < br.length; i++) {
    parts.push(`L${nf(br[i][0])} ${nf(br[i][1])}`);
  }
  parts.push(`L${nf(r)} ${nf(h)}`);

  // 左下
  const bl = cornerPoints(r, h - r, r, 3);
  for (let i = 0; i < bl.length; i++) {
    parts.push(`L${nf(bl[i][0])} ${nf(bl[i][1])}`);
  }
  parts.push(`L0 ${nf(r)}`);

  // 左上
  const tl = cornerPoints(r, r, r, 0);
  for (let i = 0; i < tl.length; i++) {
    parts.push(`L${nf(tl[i][0])} ${nf(tl[i][1])}`);
  }
  parts.push('Z');
  return parts.join(' ');
}

/** 方便调用：传 vp 尺寸 */
export function mochiRectCommandsVp(widthVp: number, heightVp: number, radiusVp: number): string {
  return mochiRectCommands(px(widthVp), px(heightVp), px(radiusVp));
}

/**
 * 自带连续曲率圆角与描边的容器。
 * 用法：MochiSurface({ radius: 20 }) { Column() { ... } }
 * 内容会被同一条路径裁切，所以子元素不会露出直角。
 */
@ComponentV2
export struct MochiSurface {
  @Param radius: number = 20;
  @Param fillColor: string = '#0DFFFFFF';
  @Param strokeColor: string = '#18FFFFFF';
  @Param strokeWidth: number = 1;
  @BuilderParam content: () => void;

  @Local w: number = 0;
  @Local h: number = 0;
  @Local cmd: string = '';

  private refresh(width: number, height: number): void {
    if (width <= 0 || height <= 0) {
      return;
    }
    const changed = Math.abs(width - this.w) > 0.5 || Math.abs(height - this.h) > 0.5;
    if (!changed) {
      return;
    }
    this.w = width;
    this.h = height;
    this.cmd = mochiRectCommands(px(width), px(height), px(this.radius));
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.cmd.length > 0) {
        Shape() {
          Path().commands(this.cmd)
        }
        .width(this.w)
        .height(this.h)
        .fill(this.fillColor)
        .stroke(this.strokeColor)
        .strokeWidth(this.strokeWidth)
        .antiAlias(true)
      }

      Column() {
        this.content()
      }
      .width('100%')
      .clipShape(new PathShape({ commands: this.cmd }))
    }
    .width('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.refresh(Number(newValue.width), Number(newValue.height));
    })
  }
}
