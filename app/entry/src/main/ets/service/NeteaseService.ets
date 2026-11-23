import { Song } from '../model/Song';
import { Logger } from '../common/Logger';
import { settings } from './SettingsService';
import { getCookie } from './NeteaseSession';
import {
  NeteasePlaylist,
  NeteasePlayUrl,
  NeteaseLyric,
  searchSongs,
  searchPlaylists,
  searchAlbums,
  resolvePlayUrl,
  fetchLyric,
  fetchPlaylistDetail,
  fetchAlbumSongs,
  fetchPersonalized,
  fetchPlaylistList,
  fetchPlaylistSummary,
  fetchRadarSongs,
  fetchDailyRecommendSongs,
  fetchPersonalFmSongs,
  fetchNewSongs,
  enrichSongs,
  TOPLIST_SOARING,
  TOPLIST_HOT,
  TOPLIST_NEW
} from './NeteaseApi';

/**
 * 网易云的「雷达歌单」是几个固定 ID，名字由官方约定。
 * 接口不提供列表，靠这组常量直接取歌单概要。
 */
class RadarDef {
  id: number;
  name: string;

  constructor(id: number, name: string) {
    this.id = id;
    this.name = name;
  }
}

const RADAR_DEFS: RadarDef[] = [
  new RadarDef(5320167908, '时光雷达'),
  new RadarDef(5362359247, '宝藏雷达'),
  new RadarDef(5300458264, '新歌雷达'),
  new RadarDef(5327906368, '乐迷雷达'),
  new RadarDef(5341776086, '神秘雷达')
];

/** 在线页当前看的是哪一类结果 */
export enum OnlineTab {
  SONG = 0,
  PLAYLIST = 1,
  ALBUM = 2
}

/** 缓存一条已解析的播放地址 */
class CachedUrl {
  info: NeteasePlayUrl = new NeteasePlayUrl();
  at: number = 0;
}

/** 首页分段的形态 */
export enum HomeBlockKind {
  /** 三首歌的小列表 */
  SONGS = 0,
  /** 横向滑动的雷达歌单 */
  RADAR = 1,
  /** 三列歌单网格 */
  PLAYLISTS = 2
}

/** 首页分段状态 */
export enum HomeBlockState {
  IDLE = 0,
  LOADING = 1,
  READY = 2,
  EMPTY = 3
}

/**
 * 首页的一个分段。
 *
 * 与安卓版一致：每段独立加载、独立显示，某一段失败不影响其它段。
 * 字段都用 @Trace，界面按段订阅，不用整页刷新。
 */
@ObservedV2
export class HomeBlock {
  key: string;
  title: string;
  glyph: string;
  kind: number;
  @Trace songs: Song[] = [];
  @Trace playlists: NeteasePlaylist[] = [];
  @Trace state: number = HomeBlockState.IDLE;
  @Trace message: string = '';

  constructor(key: string, title: string, glyph: string, kind: number) {
    this.key = key;
    this.title = title;
    this.glyph = glyph;
    this.kind = kind;
  }
}

@ObservedV2
export class NeteaseState {
  /** 搜索框里的文字 */
  @Trace keyword: string = '';
  /** 最近一次真正提交的查询，翻页/切分类要用 */
  @Trace query: string = '';
  @Trace tab: number = OnlineTab.SONG;
  @Trace searching: boolean = false;
  /** 是否已经搜过一次，决定显示首页推荐还是结果 */
  @Trace hasSearched: boolean = false;
  @Trace songs: Song[] = [];
  @Trace playlistResults: NeteasePlaylist[] = [];
  @Trace albumResults: NeteasePlaylist[] = [];
  @Trace message: string = '';

  /** 首页推荐 */
  @Trace recommended: NeteasePlaylist[] = [];
  @Trace radarPlaylists: NeteasePlaylist[] = [];
  /** 最近一次解析出来的播放地址，播放页拿它显示码率/格式 */
  @Trace lastUrlInfo: NeteasePlayUrl = new NeteasePlayUrl();
  /** 探索页的推荐歌单流（无尽） */
  @Trace explorePlaylists: NeteasePlaylist[] = [];
  @Trace exploreLoading: boolean = false;
  /** 首页分段，顺序即展示顺序 */
  @Trace homeBlocks: HomeBlock[] = [];
  @Trace homeLoading: boolean = false;
  @Trace homeMessage: string = '';

  /** 打开中的歌单/专辑详情 */
  @Trace detailOpen: boolean = false;
  @Trace detailTitle: string = '';
  @Trace detailCover: string = '';
  @Trace detailDesc: string = '';
  @Trace detailSongs: Song[] = [];
  @Trace detailLoading: boolean = false;
  @Trace detailMessage: string = '';
  /** 'playlist' | 'album' */
  detailKind: string = 'playlist';
  detailId: number = 0;

  /** 正在解析播放地址的曲目名，空串表示空闲 */
  @Trace resolvingTitle: string = '';

  /** 在线曲目是否已加入收藏，按 path 判断 */
  @Trace version: number = 0;
}

/**
 * 在线音源业务层。
 *
 * 只负责「取数据 + 解析地址」，播放动作交给 PlaybackController，
 * 歌词交给 LyricService，这样在线与本地两条链路复用同一套播放/歌词逻辑。
 */
export class NeteaseService {
  readonly state: NeteaseState = new NeteaseState();

  private homeLoaded: boolean = false;
  /** 探索页信息流：首屏拉推荐，之后按分类轮流翻歌单广场，永不结束 */
  private exploreLoaded: boolean = false;
  private exploreCat: number = 0;
  /** 排序轮换：hot 翻完换 new，同一个分类能多翻一倍 */
  private exploreOrder: number = 0;
  /**
   * 每一组「分类|排序」各自翻到第几个。
   * 不能共用一个 offset：换回某个分类时从头开始只会重复，白跑一趟。
   */
  private exploreCursors: Map<string, number> = new Map<string, number>();
  /** 连滑时别把接口打爆：两次取数之间至少隔这么久 */
  private exploreCooldownUntil: number = 0;
  /** 被限流后自动补一次，用户停在底部也不用再滑一下 */
  private exploreRetryTimer: number = -1;
  /** 加载中又收到滑动请求：等这次结束后再补一批 */
  private explorePending: boolean = false;
  /** 当前分类连着取了几页；到 3 页就换类，别让信息流一直是同一种风格 */
  private exploreCatPages: number = 0;
  private static readonly EXPLORE_CAT_PAGES: number = 3;
  private static readonly EXPLORE_PAGE: number = 48;
  /** 只对最近这么多个歌单去重：再往前的允许重新出现，信息流才能真的无尽 */
  private static readonly EXPLORE_RECENT: number = 240;
  private urlCache: Map<number, CachedUrl> = new Map<number, CachedUrl>();
  /** 网易云直链有效期约 20 分钟，这里留足余量 */
  private static readonly URL_TTL_MS: number = 10 * 60 * 1000;
  /** 切分类时没搜过的懒加载标记，避免重复请求 */
  private loadedTabs: Set<number> = new Set<number>();

  /** 第一次进探索页时拉首屏，之后不重复拉 */
  async ensureExplore(): Promise<void> {
    if (this.exploreLoaded || this.state.exploreLoading) {
      return;
    }
    await this.loadExplore(true);
  }

  /**
   * 探索页信息流，目标是「怎么划都划不到底」。
   *
   * 歌单广场每个分类都有一两千个歌单，按热度翻页足够翻很久。
   * 这里让每一组「分类 + 排序」各自记住翻到第几页（`exploreCursors`），
   * 一组翻完就换下一组，回头再轮到这一组时从上次的位置继续，不重复也不归零；
   * 去重只看最近 240 个，更早的允许重新出现。近似 30 组 × 2000 个，
   * 一个会话根本翻不完，所以界面上永远不会出现「到底了」。
   */
  async loadExplore(reset: boolean): Promise<void> {
    if (this.state.exploreLoading) {
      // 正在取的时候又滑到了底：记下来，等这次结束立刻补上，
      // 否则用户停在底部不会再有滚动事件，信息流就断在这儿了
      if (!reset) {
        this.explorePending = true;
      }
      return;
    }
    this.state.exploreLoading = true;
    try {
      // 冷却期内不丢弃这次请求，而是等冷却结束再取：
      // 用户停在列表底部不会再产生滚动事件，丢了就再也补不上
      const wait = this.exploreCooldownUntil - Date.now();
      if (!reset && wait > 0) {
        await exploreDelay(wait > 1200 ? 1200 : wait);
      }
      if (reset) {
        const first = await fetchPersonalized(12);
        this.state.explorePlaylists = first;
        this.exploreCat = 0;
        this.exploreOrder = 0;
        this.exploreCatPages = 0;
        this.exploreCursors.clear();
        this.exploreLoaded = true;
        Logger.i(`探索首屏 ${first.length} 个歌单`);
        return;
      }

      const next: NeteasePlaylist[] = this.state.explorePlaylists.slice();
      // 去重只看最近的窗口：太靠前的允许再来一次，否则迟早会「没新内容」
      const recent: Set<number> = new Set<number>();
      const from = Math.max(0, next.length - NeteaseService.EXPLORE_RECENT);
      for (let i = from; i < next.length; i++) {
        recent.add(next[i].id);
      }
      let added: number = 0;
      let tries: number = 0;
      /** 连续几页都没什么新内容；撞两次才换分类，避免在“各分类首页都是同一批热歌”上打转 */
      let lowStreak: number = 0;
      let lastPage: NeteasePlaylist[] = [];
      // 一次 48 个（约三屏）；不够再补一页
      while (added < 48 && tries < 2) {
        tries++;
        const cat = EXPLORE_CATS[this.exploreCat % EXPLORE_CATS.length];
        const order = EXPLORE_ORDERS[this.exploreOrder % EXPLORE_ORDERS.length];
        const key = `${cat}|${order}`;
        const cursor = this.exploreCursors.get(key);
        const offset = cursor === undefined ? 0 : cursor;
        const page = await fetchPlaylistList(cat, NeteaseService.EXPLORE_PAGE, offset, order);
        if (page.length === 0) {
          // 这一组翻到底了，换下一组
          this.advanceExploreCat();
          continue;
        }
        lastPage = page;
        this.exploreCursors.set(key, offset + NeteaseService.EXPLORE_PAGE);
        let fresh: number = 0;
        for (let i = 0; i < page.length; i++) {
          const p = page[i];
          if (!recent.has(p.id)) {
            recent.add(p.id);
            next.push(p);
            fresh++;
          }
        }
        added += fresh;
        this.exploreCatPages++;
        // 同一个分类翻几页就换一个，混着出内容；翻页位置留着，回头接着往深处翻
        if (this.exploreCatPages >= NeteaseService.EXPLORE_CAT_PAGES) {
          this.advanceExploreCat();
          lowStreak = 0;
          continue;
        }
        // 这一页不满说明整个分类翻到底了，换下一组
        if (page.length < NeteaseService.EXPLORE_PAGE) {
          this.advanceExploreCat();
          lowStreak = 0;
          continue;
        }
        // 新内容少：先别换分类，往同分类更深处翻——那儿才是没出现过的歌单
        if (fresh < 6) {
          lowStreak++;
          if (lowStreak >= 2) {
            this.advanceExploreCat();
            lowStreak = 0;
          }
        } else {
          lowStreak = 0;
        }
      }
      // 极端情况下所有组合都没新内容：直接续一页，宁可重复也不让信息流停住
      if (added === 0 && lastPage.length > 0) {
        for (let i = 0; i < lastPage.length; i++) {
          next.push(lastPage[i]);
        }
        added = lastPage.length;
        Logger.w('探索页没有新歌单可加，续了一页重复内容保持不断流');
      }

      this.state.explorePlaylists = next;
      this.exploreCooldownUntil = Date.now() + 300;
      this.clearExploreRetry();
      const catNow = EXPLORE_CATS[this.exploreCat % EXPLORE_CATS.length];
      const orderNow = EXPLORE_ORDERS[this.exploreOrder % EXPLORE_ORDERS.length];
      const cursorNow = this.exploreCursors.get(`${catNow}|${orderNow}`);
      Logger.i(`探索 +${added} 个，共 ${next.length} 个（${catNow}/${orderNow}`
        + ` offset=${cursorNow === undefined ? 0 : cursorNow}）`);
    } catch (e) {
      const err = e as Error;
      Logger.w(`探索页加载失败 ${err.message}`);
      // 被限流就退避一会儿，别继续打；列表保持不动
      this.exploreCooldownUntil = Date.now() + 4000;
      if (err.message.indexOf('405') >= 0 || err.message.indexOf('限流') >= 0) {
        this.scheduleExploreRetry();
      }
      if (reset) {
        this.state.explorePlaylists = [];
        this.exploreLoaded = false;
      }
    } finally {
      this.state.exploreLoading = false;
      if (this.explorePending) {
        this.explorePending = false;
        this.loadExplore(false);
      }
    }
  }

  /** 被限流时挂一个定时器：到点自动再取一次，直到成功为止 */
  private scheduleExploreRetry(): void {
    if (this.exploreRetryTimer !== -1) {
      return;
    }
    this.exploreRetryTimer = setTimeout(() => {
      this.exploreRetryTimer = -1;
      this.loadExplore(false);
    }, 16000);
  }

  private clearExploreRetry(): void {
    if (this.exploreRetryTimer !== -1) {
      clearTimeout(this.exploreRetryTimer);
      this.exploreRetryTimer = -1;
    }
  }

  /** 换下一组（分类 + 排序）；各组的翻页位置保留，回头接着翻 */
  private advanceExploreCat(): void {
    this.exploreCat++;
    this.exploreCatPages = 0;
    if (this.exploreCat >= EXPLORE_CATS.length) {
      this.exploreCat = 0;
      this.exploreOrder = (this.exploreOrder + 1) % EXPLORE_ORDERS.length;
      Logger.i(`探索页换排序：${EXPLORE_ORDERS[this.exploreOrder]}`);
    }
  }

  /**
   * 首页推荐只加载一次；失败允许用户手动重试。
   *
   * 结构与安卓版一致：一条竖向长列表，分段是
   * 私人雷达 → 雷达歌单 → 每日推荐 → 私人FM → 热力飙升 → 推荐新歌 → 热歌榜 → 新歌榜 → 为你推荐。
   * 需要登录的两段（每日推荐 / 私人FM）未登录时直接不出现。
   */
  async loadHome(force: boolean = false): Promise<void> {
    if (this.homeLoaded && !force) {
      return;
    }
    this.state.homeLoading = true;
    this.state.homeMessage = '';
    const logged = getCookie().length > 0;
    this.state.homeBlocks = this.buildHomeBlocks(logged);

    const tasks: Promise<void>[] = [];
    for (let i = 0; i < this.state.homeBlocks.length; i++) {
      tasks.push(this.loadBlock(this.state.homeBlocks[i]));
    }
    await Promise.all(tasks);

    let ready = 0;
    for (let i = 0; i < this.state.homeBlocks.length; i++) {
      if (this.state.homeBlocks[i].state === HomeBlockState.READY) {
        ready++;
      }
    }
    this.homeLoaded = ready > 0;
    if (ready === 0) {
      this.state.homeMessage = '推荐内容为空，检查网络后重试';
    }
    this.state.homeLoading = false;
    Logger.i(`在线首页：${this.state.homeBlocks.length} 段，成功 ${ready} 段`
      + `（推荐 ${this.state.recommended.length} 个，雷达 ${this.state.radarPlaylists.length} 个）`);
  }

  private buildHomeBlocks(logged: boolean): HomeBlock[] {
    const blocks: HomeBlock[] = [
      new HomeBlock('radar', '私人雷达', '◎', HomeBlockKind.SONGS),
      new HomeBlock('radarpl', '雷达歌单', '◍', HomeBlockKind.RADAR),
      new HomeBlock('soar', '热力飙升', '↑', HomeBlockKind.SONGS),
      new HomeBlock('new', '推荐新歌', '＋', HomeBlockKind.SONGS),
      new HomeBlock('hot', '热歌榜', '≡', HomeBlockKind.SONGS),
      new HomeBlock('newrank', '新歌榜', '✦', HomeBlockKind.SONGS),
      new HomeBlock('foryou', '为你推荐', '★', HomeBlockKind.PLAYLISTS)
    ];
    if (!logged) {
      return blocks;
    }
    // 登录后才有的两段，插在雷达歌单后面，和安卓版顺序一致
    const out: HomeBlock[] = [];
    for (let i = 0; i < blocks.length; i++) {
      out.push(blocks[i]);
      if (blocks[i].key === 'radarpl') {
        out.push(new HomeBlock('daily', '每日推荐', '☀', HomeBlockKind.SONGS));
        out.push(new HomeBlock('fm', '私人FM', '♪', HomeBlockKind.SONGS));
      }
    }
    return out;
  }

  /** 单段加载：失败只标记这一段，不影响其它段 */
  private async loadBlock(block: HomeBlock): Promise<void> {
    block.state = HomeBlockState.LOADING;
    try {
      if (block.kind === HomeBlockKind.RADAR) {
        const lists = await this.loadRadar();
        block.playlists = lists;
        this.state.radarPlaylists = lists;
      } else if (block.kind === HomeBlockKind.PLAYLISTS) {
        const lists = await fetchPersonalized(12);
        block.playlists = lists;
        this.state.recommended = lists;
      } else {
        block.songs = await this.songsOf(block.key);
      }
      const count = block.kind === HomeBlockKind.SONGS ? block.songs.length : block.playlists.length;
      block.state = count > 0 ? HomeBlockState.READY : HomeBlockState.EMPTY;
      if (count === 0) {
        block.message = '这一段暂时没有内容';
      }
    } catch (e) {
      const err = e as Error;
      block.state = HomeBlockState.EMPTY;
      block.message = `加载失败 ${err.message}`;
      Logger.w(`首页分段 ${block.key} 加载失败 ${err.message}`);
    }
  }

  /**
   * 首页每段拉多少首。
   * 窄屏一页露 3 首、宽屏一页露 6 首（2 列 × 3 行），剩下的靠横向滑动翻页；
   * 歌单类接口本来就是拉整份再截取，多取几首不增加请求数。
   */
  private async songsOf(key: string): Promise<Song[]> {
    // 24 首：窄屏 3 首/页 = 8 页，宽屏 6 首/页 = 4 页，正好整除不留半空页
    const take = 24;
    if (key === 'radar') {
      return await fetchRadarSongs(take);
    }
    if (key === 'daily') {
      const all = await fetchDailyRecommendSongs();
      return all.slice(0, take);
    }
    if (key === 'fm') {
      const all = await fetchPersonalFmSongs();
      return all.slice(0, take);
    }
    if (key === 'soar') {
      const all = await fetchPlaylistDetail(TOPLIST_SOARING);
      return all.slice(0, take);
    }
    if (key === 'new') {
      return await fetchNewSongs(take);
    }
    if (key === 'hot') {
      const all = await fetchPlaylistDetail(TOPLIST_HOT);
      return all.slice(0, take);
    }
    if (key === 'newrank') {
      const all = await fetchPlaylistDetail(TOPLIST_NEW);
      return all.slice(0, take);
    }
    return [];
  }

  /** 雷达歌单：并行取概要，失败也要保留名字，界面不至于空着 */
  private async loadRadar(): Promise<NeteasePlaylist[]> {
    const tasks: Promise<NeteasePlaylist | null>[] = [];
    for (let i = 0; i < RADAR_DEFS.length; i++) {
      tasks.push(fetchPlaylistSummary(RADAR_DEFS[i].id));
    }
    let results: (NeteasePlaylist | null)[] = [];
    try {
      results = await Promise.all(tasks);
    } catch (e) {
      Logger.w(`雷达歌单加载失败 ${(e as Error).message}`);
    }
    const out: NeteasePlaylist[] = [];
    for (let i = 0; i < RADAR_DEFS.length; i++) {
      const hit = i < results.length ? results[i] : null;
      if (hit !== null) {
        if (hit.name.length === 0) {
          hit.name = RADAR_DEFS[i].name;
        }
        out.push(hit);
      } else {
        const p = new NeteasePlaylist();
        p.id = RADAR_DEFS[i].id;
        p.name = RADAR_DEFS[i].name;
        out.push(p);
      }
    }
    return out;
  }

  /** 提交搜索（切分类后由 UI 再调一次） */
  async search(keyword: string): Promise<void> {
    const kw = keyword.trim();
    if (kw.length === 0) {
      this.clearSearch();
      return;
    }
    this.state.query = kw;
    this.state.keyword = kw;
    this.state.hasSearched = true;
    this.loadedTabs.clear();
    this.state.songs = [];
    this.state.playlistResults = [];
    this.state.albumResults = [];
    await this.runSearch();
  }

  /** 切换单曲/歌单/专辑，第一次切过去才请求 */
  async setTab(tab: number): Promise<void> {
    this.state.tab = tab;
    if (!this.state.hasSearched) {
      return;
    }
    if (this.loadedTabs.has(tab)) {
      return;
    }
    await this.runSearch();
  }

  private async runSearch(): Promise<void> {
    const kw = this.state.query;
    if (kw.length === 0) {
      return;
    }
    this.state.searching = true;
    this.state.message = '';
    try {
      if (this.state.tab === OnlineTab.SONG) {
        const list = await enrichSongs(await searchSongs(kw, 50, 0));
        this.state.songs = list;
        if (list.length === 0) {
          this.state.message = '没有找到相关单曲';
        }
      } else if (this.state.tab === OnlineTab.PLAYLIST) {
        const list = await searchPlaylists(kw, 30, 0);
        this.state.playlistResults = list;
        if (list.length === 0) {
          this.state.message = '没有找到相关歌单';
        }
      } else {
        const list = await searchAlbums(kw, 30, 0);
        this.state.albumResults = list;
        if (list.length === 0) {
          this.state.message = '没有找到相关专辑';
        }
      }
      this.loadedTabs.add(this.state.tab);
      Logger.i(`在线搜索「${kw}」tab=${this.state.tab} 命中见状态`);
    } catch (e) {
      const err = e as Error;
      this.state.message = `搜索失败 ${err.message}`;
      Logger.w(`在线搜索失败 ${err.message}`);
    } finally {
      this.state.searching = false;
    }
  }

  /** 清空搜索，回到首页推荐 */
  clearSearch(): void {
    this.state.keyword = '';
    this.state.query = '';
    this.state.hasSearched = false;
    this.state.songs = [];
    this.state.playlistResults = [];
    this.state.albumResults = [];
    this.state.message = '';
    this.state.searching = false;
    this.loadedTabs.clear();
  }

  /** 打开歌单详情 */
  async openPlaylist(p: NeteasePlaylist): Promise<void> {
    this.state.detailOpen = true;
    this.state.detailKind = 'playlist';
    this.state.detailId = p.id;
    this.state.detailTitle = p.name;
    this.state.detailCover = p.coverUrl;
    this.state.detailDesc = p.creator.length > 0 ? `by ${p.creator}` : '';
    this.state.detailSongs = [];
    this.state.detailLoading = true;
    this.state.detailMessage = '';
    try {
      const songs = await fetchPlaylistDetail(p.id);
      this.state.detailSongs = songs;
      if (songs.length === 0) {
        this.state.detailMessage = '这个歌单取不到曲目';
      }
    } catch (e) {
      const err = e as Error;
      this.state.detailMessage = `加载失败 ${err.message}`;
    } finally {
      this.state.detailLoading = false;
    }
  }

  /** 打开专辑详情 */
  async openAlbum(p: NeteasePlaylist): Promise<void> {
    this.state.detailOpen = true;
    this.state.detailKind = 'album';
    this.state.detailId = p.id;
    this.state.detailTitle = p.name;
    this.state.detailCover = p.coverUrl;
    this.state.detailDesc = p.creator;
    this.state.detailSongs = [];
    this.state.detailLoading = true;
    this.state.detailMessage = '';
    try {
      const songs = await fetchAlbumSongs(p.id);
      this.state.detailSongs = songs;
      if (songs.length === 0) {
        this.state.detailMessage = '这张专辑取不到曲目';
      }
    } catch (e) {
      const err = e as Error;
      this.state.detailMessage = `加载失败 ${err.message}`;
    } finally {
      this.state.detailLoading = false;
    }
  }

  closeDetail(): void {
    this.state.detailOpen = false;
    this.state.detailSongs = [];
    this.state.detailMessage = '';
  }

  /**
   * 解析一首在线曲目的可播地址，带 10 分钟缓存。
   * 失败返回空串，调用方负责提示。
   */
  async playUrlOf(song: Song): Promise<NeteasePlayUrl> {
    const empty = new NeteasePlayUrl();
    if (song.remoteId <= 0) {
      return empty;
    }
    const cached = this.urlCache.get(song.remoteId);
    if (cached !== undefined && Date.now() - cached.at < NeteaseService.URL_TTL_MS && cached.info.ok()) {
      this.state.lastUrlInfo = cached.info;
      return cached.info;
    }
    try {
      const info = await resolvePlayUrl(song.remoteId, settings.onlineLevel());
      if (info.ok()) {
        const entry = new CachedUrl();
        entry.info = info;
        entry.at = Date.now();
        this.urlCache.set(song.remoteId, entry);
        this.state.lastUrlInfo = info;
      }
      return info;
    } catch (e) {
      const err = e as Error;
      Logger.w(`解析播放地址失败 ${song.title} ${err.message}`);
      return empty;
    }
  }

  /** 账号变了（登录/退出）之后，地址与首页缓存都要作废：码率和推荐都会变 */
  async resetForAccount(): Promise<void> {
    this.urlCache.clear();
    this.homeLoaded = false;
    this.state.recommended = [];
    this.state.radarPlaylists = [];
    await this.loadHome(true);
  }

  /** 音质设置改了也清一遍，下一次播放才会用新码率 */
  clearUrlCache(): void {
    this.urlCache.clear();
  }

  /** 取在线歌词，失败返回空对象 */
  async lyricOf(song: Song): Promise<NeteaseLyric> {
    if (song.remoteId <= 0) {
      return new NeteaseLyric();
    }
    try {
      return await fetchLyric(song.remoteId);
    } catch (e) {
      const err = e as Error;
      Logger.w(`取歌词失败 ${song.title} ${err.message}`);
      return new NeteaseLyric();
    }
  }
}

export const netease: NeteaseService = new NeteaseService();

/**
 * 探索页轮转的分类。歌单广场的 cat 取值，顺序按「先大众后垂直」排，
 * 这样前几屏都是耳熟能详的，越往后越有新鲜感。
 */
/** 不含「全部」：它几乎是各分类的并集，先翻它会把后面的分类全撞掉 */
const EXPLORE_CATS: string[] = [
  '华语', '流行', '欧美', '摇滚', '民谣', '电子', '说唱', '轻音乐', '影视原声', '爵士',
  '古典', '粤语', '日语', '韩语', '小语种', 'R&B', '乡村', '游戏', '古风', '后摇',
  '金属', '蓝调', '世界音乐', '另类/独立', '夜晚', '清晨', '浪漫', '治愈', '怀旧'
];

/** 分类翻完后换排序，同一批分类还能再翻一倍 */
const EXPLORE_ORDERS: string[] = ['hot', 'new'];

/** 简单延时，给探索页的节流用 */
function exploreDelay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}
