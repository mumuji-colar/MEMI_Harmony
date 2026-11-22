/** 逐字时间（Enhanced LRC 的 <mm:ss.xx>） */
export class LyricWord {
  timeMs: number = 0;
  text: string = '';

  constructor(timeMs: number, text: string) {
    this.timeMs = timeMs;
    this.text = text;
  }
}

/** 一行歌词 */
export class LyricLine {
  /** 该行开始时间（毫秒） */
  timeMs: number = 0;
  /** 行结束后面的时间，用来给没有逐字标签的行做线性估算 */
  endTimeMs: number = 0;
  /** 歌词文本（原文） */
  text: string = '';
  /** 译文，同时间戳的第二行会合并到这里 */
  translation: string = '';
  /** 逐字时间，空数组表示这行没有逐字标签 */
  words: LyricWord[] = [];

  constructor(timeMs: number, text: string) {
    this.timeMs = timeMs;
    this.text = text;
  }
}
