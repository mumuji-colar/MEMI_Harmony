import { Song } from '../model/Song';
import {
  biliSearch,
  biliView,
  biliAudio,
  BiliSearchItem,
  BiliVideoInfo,
  BiliPage,
  BiliAudioStream
} from './BiliApi';
import { Logger } from '../common/Logger';

/**
 * 网易云拿不到地址时的兜底音源：去 B 站搜同名歌。
 *
 * 匹配规则照着安卓端抄：标题命中 55 分、歌手命中 25 分、时长接近最多 30 分，
 * 总分低于 70 视为不可信，宁可放弃也不乱配一首。
 */

export class BiliResolved {
  url: string = '';
  backupUrls: string[] = [];
  bitrateKbps: number = 0;
  mimeType: string = '';
  bvid: string = '';
  cid: number = 0;
  title: string = '';
}

class CacheEntry {
  item: BiliResolved | null = null;
  at: number = 0;
}

class PageScore {
  page: BiliPage = new BiliPage();
  score: number = 0;
}

const MIN_ACCEPT_SCORE: number = 70;
const MAX_CANDIDATES: number = 6;
const CACHE_MS: number = 10 * 60 * 1000;
/** 整次兜底最多花多久，超时就直接放弃，别让播放页一直转圈 */
const BUDGET_MS: number = 15000;

export class BiliSourceService {
  private cache: Map<number, CacheEntry> = new Map<number, CacheEntry>();

  /** 给一首在线曲目找 B 站音源；找不到返回 null */
  async resolve(song: Song): Promise<BiliResolved | null> {
    if (song.remoteId <= 0) {
      return null;
    }
    const cached = this.cache.get(song.remoteId);
    const now = Date.now();
    if (cached !== undefined && now - cached.at < CACHE_MS) {
      return cached.item;
    }

    const queries = this.buildQueries(song);
    if (queries.length === 0) {
      return null;
    }
    const deadline = now + BUDGET_MS;
    const visited: string[] = [];

    for (let qi = 0; qi < queries.length; qi++) {
      if (Date.now() > deadline) {
        Logger.w(`B站换源超时，放弃 ${song.title}`);
        break;
      }
      const items = await this.search(queries[qi], song.durationMs);
      if (items.length === 0) {
        continue;
      }
      items.sort((a: BiliSearchItem, b: BiliSearchItem) => {
        return this.scoreCandidate(song, b) - this.scoreCandidate(song, a);
      });
      const limit = Math.min(MAX_CANDIDATES, items.length);

      for (let i = 0; i < limit; i++) {
        if (Date.now() > deadline) {
          break;
        }
        const candidate = items[i];
        if (visited.indexOf(candidate.bvid) >= 0) {
          continue;
        }
        visited.push(candidate.bvid);

        const info = await biliView(candidate.bvid);
        if (info === null) {
          continue;
        }
        const match = this.selectPage(song, candidate, info);
        if (match === null || match.score < MIN_ACCEPT_SCORE) {
          continue;
        }
        const stream = await biliAudio(info.bvid, match.page.cid);
        if (stream === null) {
          continue;
        }
        const resolved = new BiliResolved();
        resolved.url = stream.url;
        resolved.backupUrls = stream.backupUrls;
        resolved.bitrateKbps = Math.round(stream.bandwidth / 1000);
        resolved.mimeType = stream.mimeType;
        resolved.bvid = info.bvid;
        resolved.cid = match.page.cid;
        resolved.title = info.title;
        Logger.i(`B站换源命中 ${song.title} → ${info.title} (${resolved.bvid}/${match.page.cid}) `
          + `分数=${match.score} ${resolved.bitrateKbps}k`);
        const entry = new CacheEntry();
        entry.item = resolved;
        entry.at = Date.now();
        this.cache.set(song.remoteId, entry);
        return resolved;
      }
    }

    // 失败也记一笔，避免重复点播放时反复搜
    const miss = new CacheEntry();
    miss.item = null;
    miss.at = Date.now();
    this.cache.set(song.remoteId, miss);
    Logger.w(`B站换源没找到匹配 ${song.title} - ${song.artist}`);
    return null;
  }

  private async search(query: string, durationMs: number): Promise<BiliSearchItem[]> {
    const filter = this.durationFilter(durationMs);
    try {
      const first = await biliSearch(query, filter);
      if (first.length > 0 || filter === 0) {
        return first;
      }
      return await biliSearch(query, 0);
    } catch (e) {
      const err = e as Error;
      Logger.w(`B站搜索失败 ${query} ${err.message}`);
      return [];
    }
  }

  /** 标题 + 歌手 → 歌手 + 标题 → 只留标题 */
  private buildQueries(song: Song): string[] {
    const title = song.title.trim();
    const artist = song.artist.trim();
    const raw: string[] = [];
    raw.push(`${title} ${artist}`);
    if (artist.length > 0) {
      raw.push(`${artist} ${title}`);
    }
    raw.push(title);
    const out: string[] = [];
    for (let i = 0; i < raw.length; i++) {
      const q = raw[i].replace(/\s+/g, ' ').trim();
      if (q.length > 0 && out.indexOf(q) < 0) {
        out.push(q);
      }
    }
    return out;
  }

  private durationFilter(durationMs: number): number {
    const sec = Math.floor(durationMs / 1000);
    if (sec <= 0) {
      return 0;
    }
    if (sec < 10 * 60) {
      return 1;
    }
    if (sec < 30 * 60) {
      return 2;
    }
    if (sec < 60 * 60) {
      return 3;
    }
    return 4;
  }

  private selectPage(song: Song, candidate: BiliSearchItem, info: BiliVideoInfo): PageScore | null {
    const candidateScore = this.scoreCandidate(song, candidate);
    let best: PageScore | null = null;
    for (let i = 0; i < info.pages.length; i++) {
      const page = info.pages[i];
      const text = `${page.part} ${info.title}`;
      const total = candidateScore + this.scoreText(song, text, info.ownerName, page.durationSec);
      if (best === null || total > best.score) {
        const ps = new PageScore();
        ps.page = page;
        ps.score = total;
        best = ps;
      }
    }
    return best;
  }

  private scoreCandidate(song: Song, item: BiliSearchItem): number {
    return this.scoreText(song, item.title, item.author, item.durationSec)
      + this.playBonus(item.play);
  }

  private scoreText(song: Song, title: string, author: string, durationSec: number): number {
    const normTitle = this.normalize(title);
    const normAuthor = this.normalize(author);
    // 歌名里的「(钢琴版)」「[原唱: xxx]」这类后缀先剥掉再比，
    // 否则只能靠「原唱/周杰伦」这种词碰运气，会配到完全不同的歌。
    const core = this.coreTitle(song.title);
    if (!this.contains(normTitle, core)) {
      return -100;
    }
    const artistHit = song.artist.length > 0
      && (this.contains(normTitle, song.artist) || this.contains(normAuthor, song.artist));

    let score = 55;
    if (artistHit) {
      score += 25;
    }
    score += this.durationScore(song.durationMs, durationSec);
    score += this.keywordBonus(title, author, song);
    return score;
  }

  /** 去掉括号修饰，留下真正的歌名 */
  private coreTitle(title: string): string {
    const stripped = title
      .replace(/\([^)]*\)/g, ' ')
      .replace(/（[^）]*）/g, ' ')
      .replace(/\[[^\]]*\]/g, ' ')
      .replace(/【[^】]*】/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
    return stripped.length >= 2 ? stripped : title.trim();
  }

  private durationScore(originalMs: number, candidateSec: number): number {
    if (originalMs <= 0 || candidateSec <= 0) {
      return 0;
    }
    const diff = Math.abs(candidateSec * 1000 - originalMs);
    if (diff <= 8000) {
      return 30;
    }
    if (diff <= 20000) {
      return 22;
    }
    if (diff <= 45000) {
      return 12;
    }
    if (candidateSec * 1000 > originalMs * 2) {
      return -15;
    }
    return 0;
  }

  /**
   * 关键词权重：官方、无损、高音质这类词优先；
   * 翻唱、伴奏、现场等版本降权。歌曲本身标题里就带这些词的（比如本来就是钢琴版）不罚。
   */
  private keywordBonus(title: string, author: string, song: Song): number {
    const text = this.normalize(`${title} ${author}`);
    const songText = this.normalize(song.title);
    let bonus = 0;

    if (text.indexOf('官方') >= 0) {
      bonus += 14;
    }
    if (text.indexOf('无损') >= 0 || text.indexOf('高音质') >= 0
      || text.indexOf('高品质') >= 0 || text.indexOf('hires') >= 0
      || text.indexOf('hi res') >= 0) {
      bonus += 10;
    }
    if (text.indexOf('完整版') >= 0 || text.indexOf('原版') >= 0 || text.indexOf('正版') >= 0) {
      bonus += 6;
    }

    const badWords: string[] = ['翻唱', 'cover', '伴奏', '纯音乐', '钢琴', '吉他', '口琴',
      '八音盒', 'dj', 'remix', '鬼畜', '片段', '试听', '直播', '现场', 'live', '串烧', '合辑'];
    for (let i = 0; i < badWords.length; i++) {
      const w = badWords[i];
      if (text.indexOf(w) >= 0 && songText.indexOf(w) < 0) {
        bonus -= 12;
      }
    }
    return bonus;
  }

  /** 播放量只做很小的加权，避免热门但不对的版本压过精确匹配 */
  private playBonus(play: number): number {
    if (play <= 0) {
      return 0;
    }
    const v = Math.log10(play) * 1.2;
    return v > 6 ? 6 : v;
  }

  private contains(normalizedText: string, rawNeedle: string): boolean {
    const needle = this.normalize(rawNeedle).replace(/ /g, '');
    if (needle.length < 2) {
      return false;
    }
    return normalizedText.replace(/ /g, '').indexOf(needle) >= 0;
  }

  /** 小写、保留中英日韩数字，其余变空格 */
  private normalize(value: string): string {
    const lower = value.toLowerCase();
    let out = '';
    for (let i = 0; i < lower.length; i++) {
      const c = lower.charAt(i);
      const code = lower.charCodeAt(i);
      const keep = (code >= 48 && code <= 57)
        || (code >= 97 && code <= 122)
        || (code >= 0x4E00 && code <= 0x9FFF)
        || (code >= 0x3040 && code <= 0x30FF)
        || (code >= 0xAC00 && code <= 0xD7AF);
      out += keep ? c : ' ';
    }
    return out.replace(/\s+/g, ' ').trim();
  }
}

export const biliSource: BiliSourceService = new BiliSourceService();
