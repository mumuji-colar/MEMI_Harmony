import { LyricLine } from '../model/LyricLine';

/** 一个字 + 上色进度（0 = 还没唱到，1 = 已唱过） */
export interface CharCell {
  ch: string;
  amount: number;
}

const DIM_R = 0x7A;
const DIM_G = 0x6A;
const DIM_B = 0x62;
/** 默认高亮色（暖橙），调用方传入主题色时会覆盖 */
const DEFAULT_HOT = '#FF8A5B';

function clamp01(v: number): number {
  if (v < 0) {
    return 0;
  }
  return v > 1 ? 1 : v;
}

function hex2(n: number): string {
  const s = Math.round(n).toString(16);
  return s.length < 2 ? `0${s}` : s;
}

function hexByte(hex: string, start: number): number {
  return parseInt(hex.substring(start, start + 2), 16);
}

/**
 * 在「未唱到」和「已唱过」两个颜色之间插值。
 * hot 传主题主色，换主题时歌词高亮会跟着变。
 */
export function lerpLyricColor(amount: number, hot: string = DEFAULT_HOT,
  dim: string = ''): string {
  const t = clamp01(amount);
  const safe = hot.length === 7 ? hot : DEFAULT_HOT;
  // 深色背景的页面（播放页/歌词页）传一个更亮的 dim，未唱的字才不会是土黄
  // 支持 #RRGGBB 与 #AARRGGBB：深色页用半透明白，未唱的字能透出封面底色
  const useDim = dim.length === 7 || dim.length === 9;
  const useAlpha = dim.length === 9;
  const da = useAlpha ? hexByte(dim, 1) : 255;
  const dr = useDim ? hexByte(dim, useAlpha ? 3 : 1) : DIM_R;
  const dg = useDim ? hexByte(dim, useAlpha ? 5 : 3) : DIM_G;
  const db = useDim ? hexByte(dim, useAlpha ? 7 : 5) : DIM_B;
  const hr = hexByte(safe, 1);
  const hg = hexByte(safe, 3);
  const hb = hexByte(safe, 5);
  const r = dr + (hr - dr) * t;
  const g = dg + (hg - dg) * t;
  const b = db + (hb - db) * t;
  if (useAlpha) {
    // alpha 也一起插值：未唱是半透明白，唱过变纯白
    const a = da + (255 - da) * t;
    return `#${hex2(a)}${hex2(r)}${hex2(g)}${hex2(b)}`;
  }
  return `#${hex2(r)}${hex2(g)}${hex2(b)}`;
}

/**
 * 把一行拆成逐字上色单元。
 *
 * amount 是浮点而不是布尔：正在唱的那个字会从灰到橙平滑过渡，
 * 不需要按像素裁切，多行折行也不会出问题。
 */
export function cellsForLine(line: LyricLine, positionMs: number): CharCell[] {
  const cells: CharCell[] = [];

  if (line.words.length > 0) {
    for (let w = 0; w < line.words.length; w++) {
      const word = line.words[w];
      const wordLen = word.text.length;
      if (wordLen === 0) {
        continue;
      }
      const nextStart = w + 1 < line.words.length ? line.words[w + 1].timeMs : line.endTimeMs;
      const span = nextStart - word.timeMs;
      let frac = 0;
      if (positionMs >= nextStart) {
        frac = 1;
      } else if (positionMs > word.timeMs && span > 0) {
        frac = (positionMs - word.timeMs) / span;
      }
      // 把这个词的整体进度摊到每个字上，字与字之间也是连续的
      const wordProgress = frac * wordLen;
      for (let i = 0; i < wordLen; i++) {
        cells.push({
          ch: word.text.charAt(i),
          amount: clamp01(wordProgress - i)
        });
      }
    }
    return cells;
  }

  const text = line.text;
  const total = text.length;
  if (total === 0) {
    return cells;
  }
  const span = line.endTimeMs - line.timeMs;
  let ratio = 0;
  if (span > 0) {
    ratio = (positionMs - line.timeMs) / span;
  } else {
    ratio = positionMs >= line.timeMs ? 1 : 0;
  }
  ratio = clamp01(ratio);
  const progressed = ratio * total;
  for (let i = 0; i < total; i++) {
    cells.push({ ch: text.charAt(i), amount: clamp01(progressed - i) });
  }
  return cells;
}
