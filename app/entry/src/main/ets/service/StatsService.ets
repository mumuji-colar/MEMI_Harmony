import { db } from './Db';
import { library } from './LibraryService';
import { Logger } from '../common/Logger';
import { Song } from '../model/Song';

/** 最常听的一行（已带上曲库信息） */
export class StatsTopItem {
  path: string = '';
  title: string = '';
  artist: string = '';
  count: number = 0;
  /** 曲库里找不到就用这个兜底 */
  inLibrary: boolean = false;
}

/** 一天的播放量 */
export class StatsDayItem {
  label: string = '';
  count: number = 0;
  isToday: boolean = false;
}

@ObservedV2
export class StatsState {
  @Trace loading: boolean = false;
  @Trace totalPlays: number = 0;
  @Trace distinctSongs: number = 0;
  /** 估算总收听时长 = Σ(该曲播放次数 × 该曲时长) */
  @Trace totalMs: number = 0;
  @Trace top: StatsTopItem[] = [];
  @Trace days: StatsDayItem[] = [];
  @Trace firstPlayAt: number = 0;
  /** 每次刷新 +1，页面可据此强制重渲染（绕过 @Trace 跨模块追踪的坑） */
  @Trace version: number = 0;
}

/**
 * 播放统计。
 *
 * 播放历史从「切歌就记一条」开始就有了，这里只做聚合展示。
 * 总时长是估算值：历史表没有记「实际听了多久」，用「次数 × 曲目时长」近似，
 * 所以比真实收听时长偏长（切歌越频繁偏差越大），在界面上标注为估算。
 */
export class StatsService {
  readonly state: StatsState = new StatsState();

  async refresh(): Promise<void> {
    this.state.loading = true;
    try {
      const totals = await db.statsTotals();
      this.state.totalPlays = totals[0];
      this.state.distinctSongs = totals[1];
      this.state.firstPlayAt = await db.firstPlayAt();

      // 按路径建索引，方便把曲库信息补到统计行上
      const byPath: Map<string, Song> = new Map();
      for (let i = 0; i < library.state.songs.length; i++) {
        const song = library.state.songs[i];
        byPath.set(song.path, song);
      }

      const rows = await db.statsTop(2000);
      const top: StatsTopItem[] = [];
      let totalMs = 0;
      for (let i = 0; i < rows.length; i++) {
        const row = rows[i];
        const song = byPath.get(row.path);
        if (song !== undefined) {
          totalMs += row.count * song.durationMs;
        }
        if (top.length >= 10) {
          continue;
        }
        const item = new StatsTopItem();
        item.path = row.path;
        item.count = row.count;
        if (song !== undefined) {
          item.title = song.title;
          item.artist = song.artist;
          item.inLibrary = true;
        } else {
          item.title = this.fallbackTitle(row.path);
          item.artist = '已不在曲库';
          item.inLibrary = false;
        }
        top.push(item);
      }
      this.state.top = top;
      this.state.totalMs = totalMs;
      Logger.i(`统计 top=${top.length} 条 totalMs=${totalMs}`);
      this.state.days = await this.buildDays();
    } catch (e) {
      Logger.w(`统计刷新失败 ${e}`);
    } finally {
      this.state.loading = false;
      this.state.version++;
    }
  }

  /** 最近 7 天，补齐没有播放的日子，柱子才能对齐 */
  private async buildDays(): Promise<StatsDayItem[]> {
    const rows = await db.statsByDay(8);
    const map: Map<string, number> = new Map();
    for (let i = 0; i < rows.length; i++) {
      map.set(rows[i].day, rows[i].count);
    }

    const out: StatsDayItem[] = [];
    const now = new Date();
    for (let i = 6; i >= 0; i--) {
      const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() - i);
      const key = this.dayKey(d);
      const item = new StatsDayItem();
      const month = d.getMonth() + 1;
      const date = d.getDate();
      item.label = `${month}/${date}`;
      item.isToday = i === 0;
      const c = map.get(key);
      item.count = c === undefined ? 0 : c;
      out.push(item);
    }
    return out;
  }

  private dayKey(d: Date): string {
    const m = d.getMonth() + 1;
    const day = d.getDate();
    const mm = m < 10 ? `0${m}` : `${m}`;
    const dd = day < 10 ? `0${day}` : `${day}`;
    return `${d.getFullYear()}-${mm}-${dd}`;
  }

  private fallbackTitle(path: string): string {
    const slash = path.lastIndexOf('/');
    return slash >= 0 ? path.substring(slash + 1) : path;
  }

  maxDayCount(): number {
    let m = 1;
    for (let i = 0; i < this.state.days.length; i++) {
      if (this.state.days[i].count > m) {
        m = this.state.days[i].count;
      }
    }
    return m;
  }

  async clear(): Promise<void> {
    await db.clearHistory();
    await this.refresh();
  }
}

export const stats: StatsService = new StatsService();
