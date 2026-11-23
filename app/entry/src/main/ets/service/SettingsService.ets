import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';

/** 一套主题色 */
export class AccentPreset {
  name: string = '';
  hex: string = '';

  constructor(name: string, hex: string) {
    this.name = name;
    this.hex = hex;
  }
}

/** 可选主题色。第一个是默认暖橙，跟旧版视觉一致 */
export const ACCENTS: AccentPreset[] = [
  new AccentPreset('暖橙', '#FF8A5B'),
  new AccentPreset('落日', '#F0708C'),
  new AccentPreset('湖青', '#4FD1C5'),
  new AccentPreset('夜紫', '#A78BFA'),
  new AccentPreset('苔绿', '#A3C46A')
];

const STORE_NAME: string = 'memi_settings';
const KEY_JSON: string = 'settings_json';

/** 落盘结构，字段变动要兼容旧值 */
interface SettingsRecord {
  accentIndex: number;
  blur: boolean;
  lyricScale: number;
  /** 翻译行字号倍率，旧版本没有这个字段 */
  transScale?: number;
  /** 底部页签与迷你播放器的通透度 0-100，旧版本没有 */
  chromeGlass?: number;
  /** 是否已同意隐私政策，旧版本没有 */
  privacyAgreed?: boolean;
  showTranslation: boolean;
  rememberProgress: boolean;
  showThumbs: boolean;
  sortMode: number;
  defaultSpeed: number;
  autoResume: boolean;
  skipShort: boolean;
  /** 在线音质档位，旧版本没有这个字段 */
  onlineQuality?: number;
  /** 动效等级 0 完整 / 1 精简 / 2 关闭 */
  motionLevel?: number;
  /** 界面缩放 0.9 / 1.0 / 1.1 */
  uiScale?: number;
  /** 同名外挂歌词优先于内嵌标签 */
  externalLyricFirst?: boolean;
}

@ObservedV2
export class SettingsState {
  @Trace accentIndex: number = 0;
  /** 毛玻璃 / 背景光斑。低端机卡就关掉 */
  @Trace blur: boolean = true;
  /** 歌词正文字号倍率，0.7 - 2.0，设置页用滑块调 */
  @Trace lyricScale: number = 1.0;
  /** 翻译行字号倍率，跟正文分开调 */
  @Trace transScale: number = 1.0;
  /**
   * 底部页签栏与迷你播放器的通透度 0-100。
   * 0 是完全实心（旧观感），越大底色越透、背景模糊越强。
   */
  @Trace chromeGlass: number = 0;
  /**
   * 是否已同意隐私政策。
   * 未同意前不发起任何网络请求，也不读取外部存储里的音频文件。
   */
  @Trace privacyAgreed: boolean = false;
  @Trace showTranslation: boolean = true;
  @Trace rememberProgress: boolean = true;
  @Trace showThumbs: boolean = true;
  /** 列表排序方式（0 标题 / 1 艺术家 / 2 时长），跟着设置一起记 */
  @Trace sortMode: number = 0;
  /** 启动时的默认倍速 */
  @Trace defaultSpeed: number = 1.0;
  /** 恢复上次位置后是否直接接着放 */
  @Trace autoResume: boolean = false;
  /** 导入时忽略短于 30 秒的音频（提示音、铃声） */
  @Trace skipShort: boolean = false;
  /** 在线音质：0 标准 / 1 高 / 2 无损 / 3 Hi-Res，实际能不能拿到看账号权限 */
  @Trace onlineQuality: number = 1;
  /** 动效：0 完整 / 1 精简 / 2 关闭。关闭后转场与旋转动画都压到 1ms */
  @Trace motionLevel: number = 0;
  /** 界面缩放：0.9 紧凑 / 1.0 标准 / 1.1 宽松，影响列表行与歌词基准字号 */
  @Trace uiScale: number = 1.0;
  /** 同名外挂 .lrc/.yrc/.ttml 优先，否则先读音频内嵌标签 */
  @Trace externalLyricFirst: boolean = true;
}

export class SettingsService {
  readonly state: SettingsState = new SettingsState();
  private store: preferences.Preferences | null = null;
  private loaded: boolean = false;

  async init(ctx: common.UIAbilityContext): Promise<void> {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    try {
      this.store = await preferences.getPreferences(ctx, STORE_NAME);
      const raw = (await this.store.get(KEY_JSON, '')) as string;
      if (raw.length === 0) {
        return;
      }
      const rec = JSON.parse(raw) as SettingsRecord;
      this.state.accentIndex = this.clampIndex(rec.accentIndex);
      this.state.blur = rec.blur !== false;
      this.state.lyricScale = this.clampScale(rec.lyricScale);
      this.state.transScale = this.clampScale(rec.transScale ?? 1.0);
      this.state.chromeGlass = this.clampPercent(rec.chromeGlass ?? 0);
      this.state.privacyAgreed = rec.privacyAgreed === true;
      this.state.showTranslation = rec.showTranslation !== false;
      this.state.rememberProgress = rec.rememberProgress !== false;
      this.state.showThumbs = rec.showThumbs !== false;
      this.state.sortMode = typeof rec.sortMode === 'number' && rec.sortMode >= 0 && rec.sortMode <= 2
        ? rec.sortMode : 0;
      this.state.defaultSpeed = typeof rec.defaultSpeed === 'number' && rec.defaultSpeed > 0
        ? rec.defaultSpeed : 1.0;
      this.state.autoResume = rec.autoResume === true;
      this.state.skipShort = rec.skipShort === true;
      this.state.onlineQuality = typeof rec.onlineQuality === 'number'
        ? Math.max(0, Math.min(3, Math.floor(rec.onlineQuality))) : 1;
      this.state.motionLevel = typeof rec.motionLevel === 'number'
        ? Math.max(0, Math.min(2, Math.floor(rec.motionLevel))) : 0;
      this.state.uiScale = this.clampUi(rec.uiScale);
      this.state.externalLyricFirst = rec.externalLyricFirst !== false;
      Logger.i(`设置已恢复 主题=${ACCENTS[this.state.accentIndex].name} 毛玻璃=${this.state.blur}`);
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`读取设置失败 ${err.code}，用默认值`);
    }
  }

  /** 主题主色 */
  accent(): string {
    return ACCENTS[this.clampIndex(this.state.accentIndex)].hex;
  }

  /**
   * 主色的半透明版本（#AARRGGBB）。
   * 用来做胶囊底色、当前行背景这类弱强调。
   */
  accentSoft(alpha: number): string {
    return this.withAlpha(this.accent(), alpha);
  }

  /** 给任意 #RRGGBB 加透明度 */
  withAlpha(hex: string, alpha: number): string {
    const a = Math.round(Math.max(0, Math.min(1, alpha)) * 255);
    const s = a.toString(16);
    const aa = s.length < 2 ? `0${s}` : s;
    return `#${aa}${hex.substring(1)}`;
  }

  /**
   * 把主题色按比例混进一个深底，返回**不透明**颜色。
   * 面板渐变的起始色要用不透明色，否则会透出后面的列表。
   */
  tintBackdrop(amount: number, base: string = '#1E1917'): string {
    const a = Math.max(0, Math.min(1, amount));
    const acc = this.accent();
    const mix = (i: number): string => {
      const b = parseInt(base.substring(i, i + 2), 16);
      const f = parseInt(acc.substring(i, i + 2), 16);
      const v = Math.round(b + (f - b) * a);
      const h = v.toString(16);
      return h.length < 2 ? `0${h}` : h;
    };
    return `#${mix(1)}${mix(3)}${mix(5)}`;
  }

  /** 按倍率缩放字号，歌词大小设置用。界面缩放会一起乘进去 */
  scale(size: number): number {
    return Math.round(size * this.state.lyricScale * this.state.uiScale);
  }

  /** 翻译行专用：倍率独立于正文，界面缩放同样要乘 */
  trans(size: number): number {
    return Math.round(size * this.state.transScale * this.state.uiScale);
  }

  /**
   * 界面缩放后的尺寸，列表行高、封面块、标题字号都走这里。
   * 只影响可读性相关的量，不改左右外边距，避免缩放后整页跟着挪。
   */
  ui(size: number): number {
    return Math.round(size * this.state.uiScale);
  }

  /** 动效时长：关闭返回 1ms（0 有些组件不认），精简折到六成 */
  motionMs(ms: number): number {
    if (this.state.motionLevel >= 2) {
      return 1;
    }
    if (this.state.motionLevel === 1) {
      return Math.max(1, Math.round(ms * 0.6));
    }
    return ms;
  }

  motionLabel(): string {
    if (this.state.motionLevel >= 2) {
      return '关闭';
    }
    return this.state.motionLevel === 1 ? '精简' : '完整';
  }

  uiLabel(): string {
    if (this.state.uiScale < 0.95) {
      return '紧凑';
    }
    return this.state.uiScale > 1.05 ? '宽松' : '标准';
  }

  async setAccentIndex(index: number): Promise<void> {
    this.state.accentIndex = this.clampIndex(index);
    await this.save();
  }

  async setBlur(on: boolean): Promise<void> {
    this.state.blur = on;
    await this.save();
  }

  async setLyricScale(scale: number): Promise<void> {
    this.state.lyricScale = this.clampScale(scale);
    await this.save();
  }

  async setTransScale(scale: number): Promise<void> {
    this.state.transScale = this.clampScale(scale);
    await this.save();
  }

  async setChromeGlass(v: number): Promise<void> {
    this.state.chromeGlass = this.clampPercent(v);
    await this.save();
  }

  async setPrivacyAgreed(v: boolean): Promise<void> {
    this.state.privacyAgreed = v;
    await this.save();
  }

  async setShowTranslation(on: boolean): Promise<void> {
    this.state.showTranslation = on;
    await this.save();
  }

  async setRememberProgress(on: boolean): Promise<void> {
    this.state.rememberProgress = on;
    await this.save();
  }

  async setDefaultSpeed(v: number): Promise<void> {
    this.state.defaultSpeed = v;
    await this.save();
  }

  async setAutoResume(on: boolean): Promise<void> {
    this.state.autoResume = on;
    await this.save();
  }

  async setSkipShort(on: boolean): Promise<void> {
    this.state.skipShort = on;
    await this.save();
  }

  async setSortMode(mode: number): Promise<void> {
    this.state.sortMode = mode;
    await this.save();
  }

  async setShowThumbs(on: boolean): Promise<void> {
    this.state.showThumbs = on;
    await this.save();
  }

  async setOnlineQuality(v: number): Promise<void> {
    this.state.onlineQuality = Math.max(0, Math.min(3, Math.floor(v)));
    await this.save();
  }

  async setMotionLevel(v: number): Promise<void> {
    this.state.motionLevel = Math.max(0, Math.min(2, Math.floor(v)));
    await this.save();
  }

  async setUiScale(v: number): Promise<void> {
    this.state.uiScale = this.clampUi(v);
    await this.save();
  }

  async setExternalLyricFirst(on: boolean): Promise<void> {
    this.state.externalLyricFirst = on;
    await this.save();
  }

  /** 备份导出用：把当前设置序列化成一份独立 JSON */
  exportJson(): string {
    const rec: SettingsRecord = {
      accentIndex: this.state.accentIndex,
      blur: this.state.blur,
      lyricScale: this.state.lyricScale,
      transScale: this.state.transScale,
      chromeGlass: this.state.chromeGlass,
      privacyAgreed: this.state.privacyAgreed,
      showTranslation: this.state.showTranslation,
      rememberProgress: this.state.rememberProgress,
      showThumbs: this.state.showThumbs,
      sortMode: this.state.sortMode,
      defaultSpeed: this.state.defaultSpeed,
      autoResume: this.state.autoResume,
      skipShort: this.state.skipShort,
      onlineQuality: this.state.onlineQuality,
      motionLevel: this.state.motionLevel,
      uiScale: this.state.uiScale,
      externalLyricFirst: this.state.externalLyricFirst
    };
    return JSON.stringify(rec);
  }

  /** 备份恢复用：解析外部 JSON，字段按旧值兜底，脏数据不至于把设置打坏 */
  async importJson(raw: string): Promise<boolean> {
    try {
      const rec = JSON.parse(raw) as SettingsRecord;
      if (rec === null || rec === undefined) {
        return false;
      }
      this.state.accentIndex = this.clampIndex(rec.accentIndex);
      this.state.blur = rec.blur !== false;
      this.state.lyricScale = this.clampScale(rec.lyricScale);
      this.state.transScale = this.clampScale(rec.transScale ?? 1.0);
      this.state.chromeGlass = this.clampPercent(rec.chromeGlass ?? 0);
      this.state.privacyAgreed = rec.privacyAgreed === true;
      this.state.showTranslation = rec.showTranslation !== false;
      this.state.rememberProgress = rec.rememberProgress !== false;
      this.state.showThumbs = rec.showThumbs !== false;
      this.state.sortMode = typeof rec.sortMode === 'number' && rec.sortMode >= 0 && rec.sortMode <= 2
        ? rec.sortMode : 0;
      this.state.defaultSpeed = typeof rec.defaultSpeed === 'number' && rec.defaultSpeed > 0
        ? rec.defaultSpeed : 1.0;
      this.state.autoResume = rec.autoResume === true;
      this.state.skipShort = rec.skipShort === true;
      this.state.onlineQuality = typeof rec.onlineQuality === 'number'
        ? Math.max(0, Math.min(3, Math.floor(rec.onlineQuality))) : 1;
      this.state.motionLevel = typeof rec.motionLevel === 'number'
        ? Math.max(0, Math.min(2, Math.floor(rec.motionLevel))) : 0;
      this.state.uiScale = this.clampUi(rec.uiScale);
      this.state.externalLyricFirst = rec.externalLyricFirst !== false;
      await this.save();
      return true;
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`导入设置失败 ${err.code}: ${err.message}`);
      return false;
    }
  }

  /** 音质档位对应的接口参数 */
  onlineLevel(): string {
    if (this.state.onlineQuality >= 3) {
      return 'hires';
    }
    if (this.state.onlineQuality === 2) {
      return 'lossless';
    }
    if (this.state.onlineQuality === 1) {
      return 'exhigh';
    }
    return 'standard';
  }

  onlineQualityLabel(): string {
    if (this.state.onlineQuality >= 3) {
      return 'Hi-Res';
    }
    if (this.state.onlineQuality === 2) {
      return '无损';
    }
    if (this.state.onlineQuality === 1) {
      return '高 320k';
    }
    return '标准 128k';
  }

  private clampIndex(v: number): number {
    if (typeof v !== 'number' || Number.isNaN(v) || v < 0 || v >= ACCENTS.length) {
      return 0;
    }
    return Math.floor(v);
  }

  private clampScale(v: number): number {
    if (typeof v !== 'number' || Number.isNaN(v)) {
      return 1.0;
    }
    if (v < 0.7) {
      return 0.7;
    }
    return v > 2.0 ? 2.0 : v;
  }

  private clampPercent(v: number): number {
    if (typeof v !== 'number' || Number.isNaN(v)) {
      return 0;
    }
    if (v < 0) {
      return 0;
    }
    return v > 100 ? 100 : v;
  }

  /** 界面缩放只开放三档，非法值一律回标准 */
  private clampUi(v: number | undefined): number {
    if (v === undefined || typeof v !== 'number' || Number.isNaN(v)) {
      return 1.0;
    }
    if (v < 0.95) {
      return 0.9;
    }
    return v > 1.05 ? 1.1 : 1.0;
  }

  private async save(): Promise<void> {
    const s = this.store;
    if (s === null) {
      return;
    }
    const rec: SettingsRecord = {
      accentIndex: this.state.accentIndex,
      blur: this.state.blur,
      lyricScale: this.state.lyricScale,
      transScale: this.state.transScale,
      chromeGlass: this.state.chromeGlass,
      privacyAgreed: this.state.privacyAgreed,
      showTranslation: this.state.showTranslation,
      rememberProgress: this.state.rememberProgress,
      showThumbs: this.state.showThumbs,
      sortMode: this.state.sortMode,
      defaultSpeed: this.state.defaultSpeed,
      autoResume: this.state.autoResume,
      skipShort: this.state.skipShort,
      onlineQuality: this.state.onlineQuality,
      motionLevel: this.state.motionLevel,
      uiScale: this.state.uiScale,
      externalLyricFirst: this.state.externalLyricFirst
    };
    try {
      await s.put(KEY_JSON, JSON.stringify(rec));
      await s.flush();
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`保存设置失败 ${err.code}`);
    }
  }
}

export const settings: SettingsService = new SettingsService();
