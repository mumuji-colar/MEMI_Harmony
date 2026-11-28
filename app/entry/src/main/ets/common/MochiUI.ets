import { curves } from '@kit.ArkUI';
import { settings } from '../service/SettingsService';

/**
 * mochiUI 的鸿蒙侧实现。
 *
 * 只覆盖 App 实际用到的部分：开关、滑块、分段控件、卡片圆角与弹簧手感。
 * 尺寸与弹簧参数取自 mochi-compose 0.1.180：
 * - Switch: 轨道 64×28，滑块 38×24，内缩 2
 * - Slider: 轨道 6，滑块 38×24，触控高 44
 * - SegmentedControl: 高 36，内缩 2，段内边距 14
 * - 形状刻度：4 / 8 / 12 / 16 / 20 / 28 / 32 / 48
 * - 弹簧：response 秒 + 阻尼比，等价于 springMotion(response, damping)
 */

/** 形状刻度，对应 mochi 的 MochiShapes */
export class MochiRadius {
  static readonly XS: number = 4;
  static readonly S: number = 8;
  static readonly M: number = 12;
  static readonly L: number = 16;
  static readonly XL: number = 20;
  static readonly XXL: number = 28;
  static readonly XXXL: number = 32;
  static readonly HUGE: number = 48;
}

/** mochi 的弹簧预设：smooth / crisp / snappy / bouncy */
export class MochiSpring {
  /** 临界阻尼，不回弹 */
  static smooth(): ICurve {
    return curves.springMotion(0.5, 1.0);
  }

  /** 一点点回弹 */
  static crisp(): ICurve {
    return curves.springMotion(0.3, 0.9);
  }

  /** 利落、带一点回弹，控件默认用它 */
  static snappy(): ICurve {
    return curves.springMotion(0.5, 0.85);
  }

  /** 明显回弹 */
  static bouncy(): ICurve {
    return curves.springMotion(0.5, 0.7);
  }

  /** 跟手拖动松手后的归位（mochi 的 MochiFollowSpring：response 0.36 / 阻尼 0.68） */
  static follow(): ICurve {
    return curves.springMotion(0.36, 0.68);
  }
}

const TRACK_OFF: string = '#3DFFFFFF';
const THUMB: string = '#FFFFFF';

@ComponentV2
export struct MochiSwitch {
  @Param isOn: boolean = false;
  @Event onToggle: (value: boolean) => void = (value: boolean) => {
  };

  @Local pressed: boolean = false;
  /** 自身维护的显示状态：父级参数不会因为 @Builder 缓存而刷新，先本地乐观更新 */
  @Local visual: boolean = false;

  aboutToAppear(): void {
    this.visual = this.isOn;
  }

  @Monitor('isOn')
  onIsOnChanged(): void {
    this.visual = this.isOn;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row()
        .width(64)
        .height(28)
        .borderRadius(14)
        .backgroundColor(this.visual ? settings.accent() : TRACK_OFF)

      Row()
        .width(38)
        .height(24)
        .borderRadius(12)
        .backgroundColor(THUMB)
        .shadow({ radius: 6, color: '#38000000', offsetX: 0, offsetY: 2 })
        .scale({ x: this.pressed ? 1.06 : 1, y: this.pressed ? 1.06 : 1 })
        .translate({ x: this.visual ? 22 : 2, y: 2 })
        .animation({ curve: MochiSpring.follow(), duration: 360 })
    }
    .width(64)
    .height(28)
    .onTouch((event: TouchEvent) => {
      // 按下时只做缩放反馈，抬手才切换。
      // 不能同时挂 onClick：Down 改状态会触发重建，点击手势会被打断。
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up) {
        this.pressed = false;
        this.visual = !this.visual;
        this.onToggle(this.visual);
      } else if (event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
  }
}

@ComponentV2
export struct MochiSlider {
  @Param value: number = 0;
  @Param min: number = 0;
  @Param max: number = 100;
  /** 是否显示右侧数值 */
  @Param showValue: boolean = false;
  @Param valueText: string = '';
  @Event onChange: (value: number) => void = (value: number) => {
  };
  @Event onChangeEnd: (value: number) => void = (value: number) => {
  };

  @Local barWidth: number = 0;
  @Local dragging: boolean = false;
  @Local dragValue: number = 0;

  private ratio(): number {
    const span = this.max - this.min;
    if (span <= 0) {
      return 0;
    }
    const v = this.dragging ? this.dragValue : this.value;
    return Math.max(0, Math.min(1, (v - this.min) / span));
  }

  private thumbW(): number {
    return 38;
  }

  private travel(): number {
    return Math.max(1, this.barWidth - this.thumbW());
  }

  private fromX(x: number): number {
    const r = Math.max(0, Math.min(1, x / this.travel()));
    return this.min + r * (this.max - this.min);
  }

  build() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        // 底轨
        Row()
          .width('100%')
          .height(6)
          .borderRadius(3)
          .backgroundColor(TRACK_OFF)
          .position({ x: 0, y: 19 })

        // 已走过的部分
        Row()
          .width(Math.max(0, this.ratio() * this.travel() + 19))
          .height(6)
          .borderRadius(3)
          .backgroundColor(settings.accent())
          .position({ x: 0, y: 19 })

        // 滑块
        Row()
          .width(this.thumbW())
          .height(24)
          .borderRadius(12)
          .backgroundColor(THUMB)
          .shadow({ radius: 8, color: '#40000000', offsetX: 0, offsetY: 2 })
          .scale({
            x: this.dragging ? 1.06 : 1,
            y: this.dragging ? 1.08 : 1
          })
          .position({ x: this.ratio() * this.travel(), y: 10 })
          .animation({ curve: MochiSpring.follow(), duration: 320 })
      }
      .layoutWeight(1)
      .height(44)
      .hitTestBehavior(HitTestMode.None)
      .onAreaChange((oldValue: Area, newValue: Area) => {
        this.barWidth = Number(newValue.width);
      })

      if (this.showValue) {
        Text(this.valueText.length > 0 ? this.valueText : `${Math.round(this.value)}`)
          .fontSize(11)
          .fontColor(settings.accent())
          .width(46)
          .textAlign(TextAlign.End)
      }
    }
    .width('100%')
    .onTouch((event: TouchEvent) => {
      if (event.touches.length === 0) {
        return;
      }
      const x = event.touches[0].x;
      if (event.type === TouchType.Down) {
        this.dragging = true;
        this.dragValue = this.fromX(x);
        this.onChange(this.dragValue);
      } else if (event.type === TouchType.Move) {
        this.dragValue = this.fromX(x);
        this.onChange(this.dragValue);
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.dragValue = this.fromX(x);
        this.onChange(this.dragValue);
        this.onChangeEnd(this.dragValue);
        this.dragging = false;
      }
    })
  }
}

@ComponentV2
export struct MochiSegmented {
  @Param items: string[] = [];
  @Param index: number = 0;
  @Event onSelect: (index: number) => void = (index: number) => {
  };

  @Local barWidth: number = 0;

  private segWidth(): number {
    const n = this.items.length;
    if (n <= 0 || this.barWidth <= 0) {
      return 0;
    }
    return (this.barWidth - 4) / n;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 选中块
      Row()
        .width(this.segWidth())
        .height(32)
        .borderRadius(16)
        .backgroundColor(settings.accentSoft(0.20))
        .borderWidth(1)
        .borderColor(settings.accentSoft(0.32))
        .translate({ x: 2 + this.index * this.segWidth(), y: 2 })
        .animation({ curve: MochiSpring.snappy(), duration: 420 })

      Row() {
        ForEach(this.items, (label: string, i: number) => {
          Text(label)
            .fontSize(13)
            .fontWeight(this.index === i ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.index === i ? settings.accent() : '#B8FFFFFF')
            .textAlign(TextAlign.Center)
            .height(36)
            .layoutWeight(1)
            .onClick(() => {
              this.onSelect(i);
            })
        }, (label: string, i: number) => `${label}_${i}`)
      }
      .width('100%')
      .padding({ left: 2, right: 2 })
    }
    .width('100%')
    .height(36)
    .borderRadius(18)
    .backgroundColor(TRACK_OFF)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.barWidth = Number(newValue.width);
    })
  }
}
