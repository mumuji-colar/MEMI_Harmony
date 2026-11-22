import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LyricLine, LyricWord } from '../model/LyricLine';
import { Logger } from '../common/Logger';
import { stemOf } from '../common/Format';
import { db } from './Db';
import { embeddedLyric } from './EmbeddedLyric';
import { Song } from '../model/Song';
import { netease } from './NeteaseService';
import { settings } from './SettingsService';

@ObservedV2
export class LyricState {
  @Trace lines: LyricLine[] = [];
  @Trace hasLyric: boolean = false;
  @Trace message: string = '';
  /** 当前高亮的行下标，-1 表示还没到第一行 */
  @Trace currentIndex: number = -1;
  /** 没有时间标签的纯文本歌词 */
  @Trace plainText: string = '';
  /** 手动偏移（毫秒），正数表示歌词提前 */
  @Trace offsetMs: number = 0;
  /** 最近一次播放位置（未加偏移），供偏移调整后立即重算 */
  positionCache: number = 0;
  /** 手动导入的歌词变动计数，界面用它触发重算 */
  @Trace externalVersion: number = 0;
}

/** [mm:ss.xx] 或 [mm:ss:xx]，毫秒位 1~3 位 */
const TIME_TAG: RegExp = new RegExp('\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]', 'g');
/** 逐字时间标签 <mm:ss.xx> */
const WORD_TAG: RegExp = new RegExp('<\\d{1,3}:\\d{1,2}(?:[.:]\\d{1,3})?>', 'g');
/** [offset:±毫秒] */
const OFFSET_TAG: RegExp = new RegExp('\\[offset:\\s*([+-]?\\d+)\\s*\\]', 'i');
/** 行内逐字标签，带捕获组 */
const WORD_INLINE: RegExp = new RegExp('<(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?>', 'g');
/** YRC 行： [startMs,durationMs](start,dur,0)字(start,dur,0)字 */
const YRC_LINE: RegExp = new RegExp('^\\[(\\d+),(\\d+)\\](.*)$');
/** YRC 词标记 */
const YRC_WORD: RegExp = new RegExp('\\((\\d+),(\\d+),\\d+\\)', 'g');
/** 制作信息行，命中就丢掉。
 *  网易云的 YRC 会把这些也做成带时间轴的行，且写法很杂：
 *  「作词 : 周杰伦」「Author（作词）：张虎」「制作人 Produced by：杜大发」
 *  所以关键词后面允许再跟一段英文说明和括号注释，再匹配冒号。 */
const CREDIT_LINE: RegExp = new RegExp(
  '^(作词|作曲|编曲|填词|制作人|制作|混音|母带|录音|和声|监制|出品|发行|词|曲|吉他|贝斯|鼓|键盘|弦乐|' +
  'lyrics?|music|arrangement|producer|mixing|mastering|composer|author|produced by)' +
  '\\s*(?:[A-Za-z][A-Za-z .]*)?\\s*(?:[（(][^）)]*[）)])?\\s*[:：]', 'i');

/** 一行解析出来的中间结果 */
interface RawEntry {
  timeMs: number;
  text: string;
  words: LyricWord[];
  order: number;
}

/**
 * 歌词加载与进度匹配。
 *
 * 支持：
 * - 普通 LRC（[mm:ss.xx]）
 * - 一行多时间戳
 * - [offset:±ms]
 * - Enhanced LRC 逐字标签 <mm:ss.xx>
 * - 双语：同时间戳的两行，第二行当译文
 *
 * 还不支持：网易云 YRC、TTML、逐字平滑擦除（目前是按字/按词着色）
 */
export class LyricService {
  readonly state: LyricState = new LyricState();
  private currentPath: string = '';
  /** 正在异步取歌词，避免 1 秒一次的 tick 重复发起 */
  private loading: boolean = false;
  /** 手动导入的歌词放在沙箱里，路径由音频路径哈希决定 */
  private overrideDir: string = '';

  init(ctx: common.UIAbilityContext): void {
    this.overrideDir = `${ctx.filesDir}/lyrics`;
    try {
      if (!fs.accessSync(this.overrideDir)) {
        fs.mkdirSync(this.overrideDir);
      }
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`创建歌词目录失败 ${err.code}`);
    }
  }

  /**
   * 统一入口：换曲就加载歌词，并把播放位置推进给当前行计算。
   *
   * 之前歌词是在播放页的 ticker 里加载的，只有打开播放页才会去取，
   * 于是退到后台时播控中心永远拿不到歌词。现在主界面和媒体会话都走这里。
   */
  async syncTo(song: Song | null, positionMs: number): Promise<void> {
    if (song !== null && song.path !== this.currentPath && !this.loading) {
      await this.ensureLoaded(song);
    }
    this.updatePosition(positionMs);
  }

  /** 按来源加载歌词（本地读文件/内嵌，在线走接口） */
  private async ensureLoaded(song: Song): Promise<void> {
    this.loading = true;
    try {
      if (song.isRemote()) {
        const data = await netease.lyricOf(song);
        const main = data.yrc.length > 0 ? data.yrc : data.lrc;
        const trans = data.yrc.length > 0
          ? (data.yrcTranslation.length > 0 ? data.yrcTranslation : data.translation)
          : data.translation;
        await this.loadForRemote(song.path, main, trans);
      } else {
        await this.loadForAudio(song.path);
      }
    } finally {
      this.loading = false;
    }
  }

  async loadForAudio(audioPath: string): Promise<void> {
    if (audioPath === this.currentPath && this.state.hasLyric) {
      return;
    }
    this.currentPath = audioPath;
    this.state.lines = [];
    this.state.currentIndex = -1;
    this.state.hasLyric = false;
    this.state.message = '';

    if (audioPath.length === 0) {
      return;
    }

    const slash = audioPath.lastIndexOf('/');
    if (slash < 0) {
      return;
    }
    const dir = audioPath.substring(0, slash);
    const name = audioPath.substring(slash + 1);
    const stem = stemOf(name);
    let lrcPath = `${dir}/${stem}.lrc`;
    if (!fs.accessSync(lrcPath)) {
      lrcPath = `${dir}/${stem}.yrc`;
    }
    if (!fs.accessSync(lrcPath)) {
      lrcPath = `${dir}/${stem}.ttml`;
    }

    // 优先级：手动导入 > 同名外挂文件 / 音频内嵌标签（顺序看设置）> 无歌词
    const ownPath = this.overridePath(audioPath);
    const useOwn = ownPath.length > 0 && fs.accessSync(ownPath);
    // 关掉「外部歌词优先」时先读音频标签，适合外挂文件配错的老资源
    const sidecarFirst = settings.state.externalLyricFirst;

    try {
      if (useOwn) {
        this.applyContent(this.readTextSmart(ownPath), '手动导入');
      } else if (sidecarFirst && fs.accessSync(lrcPath)) {
        this.applyContent(this.readTextSmart(lrcPath), lrcPath);
      } else {
        // 没有同名歌词文件（或用户要求内嵌优先），先试着从音频标签里抠
        const embeddedText = embeddedLyric.read(audioPath);
        if (embeddedText.length > 0) {
          this.applyContent(embeddedText, '内嵌标签');
        } else if (fs.accessSync(lrcPath)) {
          this.applyContent(this.readTextSmart(lrcPath), lrcPath);
        } else {
          this.state.message = '没有找到歌词文件，音频里也没有内嵌歌词';
          Logger.i('无外挂歌词，也无内嵌歌词');
          return;
        }
      }
      if (!useOwn) {
        this.applyTranslationSidecar(dir, stem);
      }
      this.state.offsetMs = await db.loadLyricOffset(audioPath);
      if (this.state.offsetMs !== 0) {
        Logger.i(`该曲歌词偏移 ${this.state.offsetMs}ms`);
      }
    } catch (e) {
      const err = e as BusinessError;
      this.state.message = `歌词读取失败 ${err.code}`;
      Logger.w(`歌词读取失败 ${lrcPath} ${err.code}: ${err.message}`);
    }
  }

  /**
   * 下载时会把翻译单独存成 `<stem>.trans`（或 `.tlyric`），
   * 这里按时间戳贴回原文行。没有就静默跳过。
   */
  private applyTranslationSidecar(dir: string, stem: string): void {
    if (this.state.lines.length === 0) {
      return;
    }
    let path = `${dir}/${stem}.trans`;
    if (!fs.accessSync(path)) {
      path = `${dir}/${stem}.tlyric`;
    }
    if (!fs.accessSync(path)) {
      return;
    }
    try {
      const table = this.buildTranslationTable(this.readTextSmart(path));
      if (table.size === 0) {
        return;
      }
      let merged = 0;
      for (let i = 0; i < this.state.lines.length; i++) {
        const line = this.state.lines[i];
        const hit = table.get(line.timeMs);
        if (hit !== undefined && hit !== line.text) {
          line.translation = hit;
          merged++;
        }
      }
      if (merged > 0) {
        this.state.lines = this.state.lines.slice();
        Logger.i(`外挂翻译已合并 ${merged} 行`);
      }
    } catch (e) {
      Logger.w(`读外挂翻译失败 ${(e as Error).message}`);
    }
  }

  /** 下载补了歌词之后，让当前这首重新读一次 */
  async reloadForAudio(audioPath: string): Promise<void> {
    if (audioPath.length === 0 || audioPath !== this.currentPath) {
      return;
    }
    this.currentPath = '';
    await this.loadForAudio(audioPath);
  }

  /** 无条件重读，导入/删掉歌词文件后用 */
  async refresh(audioPath: string): Promise<void> {
    if (audioPath.length === 0) {
      return;
    }
    this.currentPath = '';
    await this.loadForAudio(audioPath);
  }

  /** 这首歌有没有手动导入过歌词 */
  hasExternal(audioPath: string): boolean {
    const p = this.overridePath(audioPath);
    if (p.length === 0) {
      return false;
    }
    try {
      return fs.accessSync(p);
    } catch (e) {
      return false;
    }
  }

  /**
   * 把用户选的 .lrc/.yrc/.ttml 拷进沙箱，之后这首歌一直用它。
   * 不写到音频同目录：音频多半在选择器给的目录里，应用没有写权限。
   */
  async importExternal(audioPath: string, srcUri: string): Promise<boolean> {
    if (audioPath.length === 0 || srcUri.length === 0) {
      return false;
    }
    const dest = this.overridePath(audioPath);
    if (dest.length === 0) {
      Logger.w('歌词目录未初始化，无法导入');
      return false;
    }
    try {
      if (!fs.accessSync(this.overrideDir)) {
        fs.mkdirSync(this.overrideDir);
      }
      const text = this.readTextSmart(srcUri);
      if (text.trim().length === 0) {
        Logger.w('选中的歌词文件是空的');
        return false;
      }
      const f = fs.openSync(dest, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, text);
      } finally {
        fs.closeSync(f.fd);
      }
      Logger.i(`歌词已导入 ${dest}`);
      this.state.externalVersion++;
      await this.refresh(audioPath);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`导入歌词失败 ${err.code}: ${err.message}`);
      return false;
    }
  }

  /** 删掉手动导入的歌词，回到外挂/内嵌 */
  async removeExternal(audioPath: string): Promise<boolean> {
    const dest = this.overridePath(audioPath);
    if (dest.length === 0 || !this.hasExternal(audioPath)) {
      return false;
    }
    try {
      await fs.unlink(dest);
      Logger.i('手动导入的歌词已删除');
      this.state.externalVersion++;
      await this.refresh(audioPath);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`删除导入歌词失败 ${err.code}`);
      return false;
    }
  }

  /** 沙箱里对应的歌词文件路径，空串表示还没初始化 */
  private overridePath(audioPath: string): string {
    if (this.overrideDir.length === 0 || audioPath.length === 0) {
      return '';
    }
    return `${this.overrideDir}/${this.hashOf(audioPath)}.lrc`;
  }

  /** FNV-1a 32 位，够用来当文件名，也不需要额外依赖 */
  private hashOf(input: string): string {
    let h = 0x811c9dc5;
    for (let i = 0; i < input.length; i++) {
      h = h ^ input.charCodeAt(i);
      h = Math.imul(h, 0x01000193) >>> 0;
    }
    let hex = h.toString(16);
    while (hex.length < 8) {
      hex = `0${hex}`;
    }
    return hex;
  }

  /** 解析并写入状态，外挂文件和内嵌标签共用 */
  private applyContent(content: string, source: string): void {
    const parsed = this.parseContent(content);
    this.state.lines = parsed.lines;
    this.state.plainText = parsed.plain;
    this.state.hasLyric = parsed.lines.length > 0;
    this.state.message = this.state.hasLyric || parsed.plain.length > 0
      ? '' : '歌词内容里没有可用行';
    Logger.i(`歌词已加载 ${parsed.lines.length} 行${parsed.plain.length > 0 ? '（纯文本）' : ''} 来源=${source}`);
  }

  /**
   * 在线曲目：网易云把原文和翻译分成两个字段返回，
   * 所以先解析原文，再按时间戳把译文贴到对应行上。
   */
  async loadForRemote(pathKey: string, main: string, translation: string): Promise<void> {
    if (pathKey === this.currentPath) {
      return;
    }
    this.currentPath = pathKey;
    this.state.lines = [];
    this.state.currentIndex = -1;
    this.state.hasLyric = false;
    this.state.plainText = '';
    this.state.message = '';
    this.state.offsetMs = 0;

    if (pathKey.length === 0) {
      return;
    }
    if (main.length === 0) {
      this.state.message = '这首歌没有歌词';
      Logger.i('在线曲目无歌词');
      return;
    }

    try {
      const parsed = this.parseContent(main);
      if (translation.length > 0 && parsed.lines.length > 0) {
        const table = this.buildTranslationTable(translation);
        if (table.size > 0) {
          for (let i = 0; i < parsed.lines.length; i++) {
            const line = parsed.lines[i];
            const hit = table.get(line.timeMs);
            if (hit !== undefined && hit !== line.text) {
              line.translation = hit;
            }
          }
        }
      }
      this.state.lines = parsed.lines;
      this.state.plainText = parsed.plain;
      this.state.hasLyric = parsed.lines.length > 0;
      this.state.message = this.state.hasLyric || parsed.plain.length > 0 ? '' : '歌词内容里没有可用行';
      this.state.offsetMs = await db.loadLyricOffset(pathKey);
      Logger.i(`在线歌词已加载 ${parsed.lines.length} 行，翻译 ${translation.length > 0 ? '有' : '无'}`);
    } catch (e) {
      const err = e as BusinessError;
      this.state.message = `歌词解析失败 ${err.code}`;
      Logger.w(`在线歌词解析失败 ${err.code}: ${err.message}`);
    }
  }

  /**
   * 译文时间表。LRC 与 YRC 两种写法都吃：
   *   [00:24.08]译文   /   [24080,5080](24080,280,0)译(24360,210,0)文
   * YRC 译文的时间戳与原文逐行对齐，直接按起始毫秒索引即可。
   */
  private buildTranslationTable(content: string): Map<number, string> {
    const table: Map<number, string> = new Map();
    const isYrc = this.looksLikeYrc(content);
    const rawLines: string[] = content.split('\n');
    for (let i = 0; i < rawLines.length; i++) {
      const t = rawLines[i].trim();
      if (t.length === 0) {
        continue;
      }
      if (isYrc) {
        const m = t.match(YRC_LINE);
        if (m === null) {
          continue;
        }
        const start = Number(m[1]);
        const body = m[3];
        let text = '';
        YRC_WORD.lastIndex = 0;
        let w = YRC_WORD.exec(body);
        let cursor = 0;
        while (w !== null) {
          text += body.substring(cursor, w.index);
          cursor = YRC_WORD.lastIndex;
          w = YRC_WORD.exec(body);
        }
        text += body.substring(cursor);
        const clean = text.trim();
        if (clean.length > 0 && !Number.isNaN(start)) {
          table.set(start, clean);
        }
      } else {
        TIME_TAG.lastIndex = 0;
        let m = TIME_TAG.exec(t);
        let lastEnd = 0;
        let startMs = -1;
        while (m !== null) {
          if (startMs < 0) {
            startMs = this.toMs(m[1], m[2], m[3]);
          }
          lastEnd = TIME_TAG.lastIndex;
          m = TIME_TAG.exec(t);
        }
        if (startMs < 0) {
          continue;
        }
        const text = t.substring(lastEnd).replace(WORD_TAG, '').trim();
        if (text.length > 0) {
          table.set(startMs, text);
        }
      }
    }
    return table;
  }

  /** 播放位置加上偏移后的值，渲染逐字进度也要用这个 */
  adjust(positionMs: number): number {
    return positionMs + this.state.offsetMs;
  }

  async nudgeOffset(deltaMs: number): Promise<void> {
    await this.setOffset(this.state.offsetMs + deltaMs);
  }

  async setOffset(offsetMs: number): Promise<void> {
    this.state.offsetMs = offsetMs;
    // 位置变了要立刻重算当前行，否则要等下一次 tick
    this.updatePositionForced();
    await db.saveLyricOffset(this.currentPath, offsetMs);
  }

  private updatePositionForced(): void {
    const pos = this.state.positionCache + this.state.offsetMs;
    const lines = this.state.lines;
    if (lines.length === 0) {
      return;
    }
    let idx = -1;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].timeMs <= pos) {
        idx = i;
      } else {
        break;
      }
    }
    this.state.currentIndex = idx;
  }

  /** 按播放进度更新当前行 */
  updatePosition(positionMs: number): void {
    this.state.positionCache = positionMs;
    const lines = this.state.lines;
    if (lines.length === 0) {
      return;
    }
    positionMs = positionMs + this.state.offsetMs;
    let idx = -1;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].timeMs <= positionMs) {
        idx = i;
      } else {
        break;
      }
    }
    if (idx !== this.state.currentIndex) {
      this.state.currentIndex = idx;
    }
  }

  clear(): void {
    this.currentPath = '';
    this.state.lines = [];
    this.state.currentIndex = -1;
    this.state.hasLyric = false;
    this.state.plainText = '';
    this.state.message = '';
  }

  /**
   * 先按 UTF-8 读，出现替换字符再按 GBK 重试。
   * 国内下载的 lrc 有一大半还是 GBK，不做这个兜底全是乱码。
   */
  private readTextSmart(path: string): string {
    const bytes = this.readAllBytes(path);
    let text = this.decode(bytes, 'utf-8');
    if (text.indexOf('\uFFFD') >= 0) {
      Logger.i('检测到编码异常，改用 GBK 解码');
      text = this.decode(bytes, 'gbk');
    }
    if (text.length > 0 && text.charCodeAt(0) === 0xFEFF) {
      text = text.substring(1);
    }
    return text;
  }

  private readAllBytes(path: string): Uint8Array {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const size = fs.statSync(file.fd).size;
      const buffer = new ArrayBuffer(size);
      fs.readSync(file.fd, buffer);
      return new Uint8Array(buffer);
    } finally {
      fs.closeSync(file.fd);
    }
  }

  private decode(bytes: Uint8Array, encoding: string): string {
    try {
      const decoder = util.TextDecoder.create(encoding, { ignoreBOM: true });
      return decoder.decodeToString(bytes);
    } catch (e) {
      Logger.w(`解码器 ${encoding} 不可用，回落 utf-8`);
      return util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(bytes);
    }
  }

  /** 解析 LRC 文本 */
  private parse(content: string): LyricLine[] {
    let offsetMs = 0;
    const offsetMatch = content.match(OFFSET_TAG);
    if (offsetMatch !== null && offsetMatch.length > 1) {
      const parsed = Number(offsetMatch[1]);
      if (!Number.isNaN(parsed)) {
        offsetMs = parsed;
      }
    }

    const entries: RawEntry[] = [];
    const rawLines: string[] = content.split('\n');
    let order = 0;

    for (let i = 0; i < rawLines.length; i++) {
      const raw = rawLines[i].trim();
      if (raw.length === 0) {
        continue;
      }
      TIME_TAG.lastIndex = 0;
      const stamps: number[] = [];
      let m = TIME_TAG.exec(raw);
      let lastEnd = 0;
      while (m !== null) {
        stamps.push(this.toMs(m[1], m[2], m[3]));
        lastEnd = TIME_TAG.lastIndex;
        m = TIME_TAG.exec(raw);
      }
      if (stamps.length === 0) {
        continue;
      }

      const body = raw.substring(lastEnd);
      const parsed = this.parseWords(body);
      if (parsed.text.length === 0) {
        continue;
      }
      // 「作词: xx」这类制作信息不是歌词，直接丢掉
      if (CREDIT_LINE.test(parsed.text)) {
        continue;
      }
      for (let s = 0; s < stamps.length; s++) {
        const words: LyricWord[] = [];
        for (let w = 0; w < parsed.words.length; w++) {
          words.push(new LyricWord(parsed.words[w].timeMs + offsetMs, parsed.words[w].text));
        }
        entries.push({
          timeMs: stamps[s] + offsetMs,
          text: parsed.text,
          words: words,
          order: order++
        });
      }
    }

    entries.sort((a: RawEntry, b: RawEntry) => {
      if (a.timeMs !== b.timeMs) {
        return a.timeMs - b.timeMs;
      }
      return a.order - b.order;
    });

    return this.buildLines(entries);
  }

  /**
   * 同时间戳的两行合并成「原文 + 译文」。
   * 双语 LRC 基本都是这种写法：先原文一行，紧跟一行时间戳完全相同的译文。
   */
  private buildLines(entries: RawEntry[]): LyricLine[] {
    const lines: LyricLine[] = [];
    let i = 0;
    while (i < entries.length) {
      const head = entries[i];
      const line = new LyricLine(head.timeMs, head.text);
      line.words = head.words;

      let consumed = 1;
      // 往下吃掉时间戳相同（±20ms）且没被合并过的行
      for (let j = i + 1; j < entries.length; j++) {
        if (Math.abs(entries[j].timeMs - head.timeMs) > 20) {
          break;
        }
        if (line.translation.length === 0 && entries[j].text !== head.text) {
          line.translation = entries[j].text;
        }
        consumed++;
      }

      lines.push(line);
      i += consumed;
    }

    // 用下一行的开始时间补齐本行结束时间，最后一行兜底 +4 秒
    for (let k = 0; k < lines.length; k++) {
      if (k + 1 < lines.length) {
        lines[k].endTimeMs = lines[k + 1].timeMs;
      } else {
        lines[k].endTimeMs = lines[k].timeMs + 4000;
      }
      if (lines[k].endTimeMs <= lines[k].timeMs) {
        lines[k].endTimeMs = lines[k].timeMs + 1000;
      }
    }
    return lines;
  }

  /** 解析行内逐字标签，返回纯文本 + 词时间 */
  private parseWords(body: string): ParsedBody {
    WORD_INLINE.lastIndex = 0;
    const words: LyricWord[] = [];
    let m = WORD_INLINE.exec(body);
    if (m === null) {
      // 没有逐字标签，按整行处理
      return { text: body.replace(WORD_TAG, '').trim(), words: [] };
    }

    let cursor = 0;
    let pendingTime = -1;
    while (m !== null) {
      const before = body.substring(cursor, m.index);
      if (before.length > 0) {
        if (pendingTime >= 0) {
          words.push(new LyricWord(pendingTime, before));
        } else {
          // 第一个标签之前的文字挂到第一个标签时间上
          words.push(new LyricWord(this.toMs(m[1], m[2], m[3]), before));
        }
      }
      pendingTime = this.toMs(m[1], m[2], m[3]);
      cursor = WORD_INLINE.lastIndex;
      m = WORD_INLINE.exec(body);
    }

    const tail = body.substring(cursor);
    if (tail.length > 0 && pendingTime >= 0) {
      words.push(new LyricWord(pendingTime, tail));
    }

    let text = '';
    for (let i = 0; i < words.length; i++) {
      text += words[i].text;
    }
    return { text: text.trim(), words: words };
  }

  /** 先判断格式，再选解析器；都没有时间标签就退化成纯文本 */
  private parseContent(content: string): ParsedLyric {
    if (this.looksLikeTtml(content)) {
      const ttmlLines = this.parseTtml(content);
      if (ttmlLines.length > 0) {
        Logger.i('识别为 TTML 歌词');
        return { lines: ttmlLines, plain: '' };
      }
    }
    if (this.looksLikeYrc(content)) {
      const yrcLines = this.parseYrc(content);
      if (yrcLines.length > 0) {
        Logger.i('识别为 YRC 逐字歌词');
        return { lines: yrcLines, plain: '' };
      }
    }
    const lrcLines = this.parse(content);
    if (lrcLines.length > 0) {
      return { lines: lrcLines, plain: '' };
    }
    return { lines: [], plain: this.toPlain(content) };
  }

  private looksLikeYrc(content: string): boolean {
    const lines = content.split('\n');
    let hits = 0;
    for (let i = 0; i < lines.length && hits < 2; i++) {
      const t = lines[i].trim();
      if (t.length === 0) {
        continue;
      }
      if (t.match(YRC_LINE) !== null && t.indexOf('(') >= 0) {
        hits++;
      }
    }
    return hits >= 2;
  }

  /** 网易云 YRC：每行 [起始,时长](词起始,词时长,0)字... */
  private parseYrc(content: string): LyricLine[] {
    const out: LyricLine[] = [];
    const rawLines = content.split('\n');
    for (let i = 0; i < rawLines.length; i++) {
      const t = rawLines[i].trim();
      if (t.length === 0) {
        continue;
      }
      const m = t.match(YRC_LINE);
      if (m === null) {
        continue;
      }
      const start = Number(m[1]);
      const dur = Number(m[2]);
      const body = m[3];

      const words: LyricWord[] = [];
      YRC_WORD.lastIndex = 0;
      let w = YRC_WORD.exec(body);
      let cursor = 0;
      let pending = -1;
      while (w !== null) {
        const before = body.substring(cursor, w.index);
        if (before.length > 0 && pending >= 0) {
          words.push(new LyricWord(pending, before));
        }
        pending = Number(w[1]);
        cursor = YRC_WORD.lastIndex;
        w = YRC_WORD.exec(body);
      }
      const tail = body.substring(cursor);
      if (tail.length > 0 && pending >= 0) {
        words.push(new LyricWord(pending, tail));
      }

      let text = '';
      for (let k = 0; k < words.length; k++) {
        text += words[k].text;
      }
      text = text.trim();
      if (text.length === 0 || CREDIT_LINE.test(text)) {
        continue;
      }
      const line = new LyricLine(start, text);
      line.words = words;
      line.endTimeMs = start + (dur > 0 ? dur : 2000);
      out.push(line);
    }
    out.sort((a: LyricLine, b: LyricLine) => a.timeMs - b.timeMs);
    return out;
  }

  private looksLikeTtml(content: string): boolean {
    return content.indexOf('<tt') >= 0 || content.indexOf('<TT') >= 0;
  }

  /**
   * TTML（B 站 / YouTube Music 用的格式）。
   * 只取行级 begin/end，行内 <span> 的词时间先忽略，文本拼起来即可。
   */
  private parseTtml(content: string): LyricLine[] {
    const out: LyricLine[] = [];
    // <p ... begin="..." ...>内容</p>
    const pTag = new RegExp('<p\\b([^>]*)>([\\s\\S]*?)</p>', 'gi');
    const beginAttr = new RegExp('begin="([^"]+)"', 'i');
    const endAttr = new RegExp('end="([^"]+)"', 'i');

    let m = pTag.exec(content);
    while (m !== null) {
      const attrs = m[1];
      const body = m[2];
      const bm = attrs.match(beginAttr);
      if (bm !== null) {
        const start = this.parseTtmlTime(bm[1]);
        const text = this.cleanTtmlText(body);
        if (start >= 0 && text.length > 0 && !CREDIT_LINE.test(text)) {
          const line = new LyricLine(start, text);
          const em = attrs.match(endAttr);
          line.endTimeMs = em !== null ? this.parseTtmlTime(em[1]) : start + 2000;
          out.push(line);
        }
      }
      m = pTag.exec(content);
    }

    out.sort((a: LyricLine, b: LyricLine) => a.timeMs - b.timeMs);
    // end 缺失或异常时用下一行补齐
    for (let i = 0; i < out.length; i++) {
      if (out[i].endTimeMs <= out[i].timeMs) {
        out[i].endTimeMs = i + 1 < out.length ? out[i + 1].timeMs : out[i].timeMs + 4000;
      }
    }
    return out;
  }

  /** "00:00:01.500" / "00:01.500" / "1.5" 都转毫秒 */
  private parseTtmlTime(v: string): number {
    const t = v.trim();
    const parts = t.split(':');
    try {
      if (parts.length === 3) {
        const h = Number(parts[0]);
        const mn = Number(parts[1]);
        const sec = Number(parts[2]);
        return Math.round((h * 3600 + mn * 60 + sec) * 1000);
      }
      if (parts.length === 2) {
        const mn = Number(parts[0]);
        const sec = Number(parts[1]);
        return Math.round((mn * 60 + sec) * 1000);
      }
      if (parts.length === 1) {
        return Math.round(Number(parts[0]) * 1000);
      }
    } catch (e) {
      Logger.w(`TTML 时间解析失败 ${v}`);
    }
    return -1;
  }

  private cleanTtmlText(body: string): string {
    let t = body.replace(new RegExp('<br\\s*/?>', 'gi'), '\n');
    t = t.replace(new RegExp('<[^>]+>', 'g'), '');
    t = t.replace(new RegExp('&amp;', 'g'), '&')
      .replace(new RegExp('&lt;', 'g'), '<')
      .replace(new RegExp('&gt;', 'g'), '>')
      .replace(new RegExp('&quot;', 'g'), '"')
      .replace(new RegExp('&nbsp;', 'g'), ' ')
      .replace(new RegExp('&#39;', 'g'), "'");
    return t.trim();
  }

  /** 没有任何时间标签时，把文本洗干净当静态歌词 */
  private toPlain(content: string): string {
    const rawLines = content.split('\n');
    const kept: string[] = [];
    for (let i = 0; i < rawLines.length; i++) {
      let t = rawLines[i].replace(TIME_TAG, '').replace(WORD_TAG, '').trim();
      if (t.length === 0) {
        continue;
      }
      if (t.startsWith('[') && t.endsWith(']')) {
        continue;
      }
      if (CREDIT_LINE.test(t)) {
        continue;
      }
      kept.push(t);
    }
    return kept.join('\n');
  }

  private toMs(minStr: string, secStr: string, fracStr: string | undefined): number {
    const min = Number(minStr);
    const sec = Number(secStr);
    let ms = 0;
    if (fracStr !== undefined) {
      ms = fracStr.length === 1 ? Number(fracStr) * 100
        : (fracStr.length === 2 ? Number(fracStr) * 10 : Number(fracStr));
    }
    return min * 60000 + sec * 1000 + ms;
  }
}

interface ParsedLyric {
  lines: LyricLine[];
  plain: string;
}

interface ParsedBody {
  text: string;
  words: LyricWord[];
}

export const lyric: LyricService = new LyricService();
