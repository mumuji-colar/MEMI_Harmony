import { Song } from '../model/Song';
import { Logger } from '../common/Logger';
import {
  NeteaseArtistInfo,
  NeteaseMv,
  NeteasePlaylist,
  fetchArtistInfo,
  fetchArtistSongs,
  fetchArtistAlbums,
  fetchArtistMvs
} from './NeteaseApi';

/** 艺人页的三个页签 */
export enum ArtistTab {
  SONG = 0,
  ALBUM = 1,
  MV = 2
}

const SONG_PAGE: number = 50;
const ALBUM_PAGE: number = 30;
const MV_PAGE: number = 20;

@ObservedV2
export class ArtistState {
  @Trace open: boolean = false;
  @Trace loading: boolean = false;
  @Trace artistId: number = 0;
  @Trace name: string = '';
  @Trace avatarUrl: string = '';
  @Trace alias: string = '';
  @Trace brief: string = '';
  @Trace albumCount: number = 0;
  @Trace songCount: number = 0;
  @Trace mvCount: number = 0;
  @Trace tab: number = ArtistTab.SONG;
  @Trace songs: Song[] = [];
  @Trace albums: NeteasePlaylist[] = [];
  @Trace mvs: NeteaseMv[] = [];
  @Trace message: string = '';
  @Trace loadingMore: boolean = false;
  @Trace hasMore: boolean = false;
}

/**
 * 艺人主页。
 *
 * 只维护一个「当前艺人」的状态，页面用浮层呈现，所以不需要多实例。
 * 三个页签各自懒加载，切回来不会重复请求。
 */
export class NeteaseArtistService {
  readonly state: ArtistState = new ArtistState();
  /** 每次 open +1，用来丢弃过期的网络结果（快速点不同歌手时） */
  private seq: number = 0;

  async open(artistId: number, name: string): Promise<void> {
    if (artistId <= 0) {
      return;
    }
    this.seq++;
    const mine = this.seq;
    this.state.open = true;
    this.state.loading = true;
    this.state.artistId = artistId;
    this.state.name = name;
    this.state.avatarUrl = '';
    this.state.alias = '';
    this.state.brief = '';
    this.state.albumCount = 0;
    this.state.songCount = 0;
    this.state.mvCount = 0;
    this.state.tab = ArtistTab.SONG;
    this.state.songs = [];
    this.state.albums = [];
    this.state.mvs = [];
    this.state.message = '';
    this.state.hasMore = false;

    try {
      const info = await fetchArtistInfo(artistId);
      if (mine !== this.seq) {
        return;
      }
      if (info !== null) {
        this.applyInfo(info);
      }
      await this.loadSongs(true, mine);
    } catch (e) {
      if (mine !== this.seq) {
        return;
      }
      this.state.message = `加载失败 ${(e as Error).message}`;
      Logger.w(`艺人页加载失败 ${(e as Error).message}`);
    } finally {
      if (mine === this.seq) {
        this.state.loading = false;
      }
    }
  }

  private applyInfo(info: NeteaseArtistInfo): void {
    this.state.name = info.name.length > 0 ? info.name : this.state.name;
    this.state.avatarUrl = info.avatarUrl.length > 0 ? info.avatarUrl : info.coverUrl;
    this.state.alias = info.alias;
    this.state.brief = info.briefDesc;
    this.state.albumCount = info.albumSize;
    this.state.songCount = info.musicSize;
    this.state.mvCount = info.mvSize;
  }

  close(): void {
    this.state.open = false;
    this.seq++;
  }

  /** 切页签，首次进入才请求 */
  async setTab(tab: number): Promise<void> {
    if (this.state.tab === tab) {
      return;
    }
    this.state.tab = tab;
    if (tab === ArtistTab.SONG && this.state.songs.length === 0) {
      await this.loadSongs(true, this.seq);
    } else if (tab === ArtistTab.ALBUM && this.state.albums.length === 0) {
      await this.loadAlbums(true, this.seq);
    } else if (tab === ArtistTab.MV && this.state.mvs.length === 0) {
      await this.loadMvs(true, this.seq);
    }
  }

  /** 触底加载下一页（当前页签） */
  async loadMore(): Promise<void> {
    if (!this.state.hasMore || this.state.loadingMore || this.state.artistId <= 0) {
      return;
    }
    const mine = this.seq;
    if (this.state.tab === ArtistTab.SONG) {
      await this.loadSongs(false, mine);
    } else if (this.state.tab === ArtistTab.ALBUM) {
      await this.loadAlbums(false, mine);
    } else {
      await this.loadMvs(false, mine);
    }
  }

  private async loadSongs(reset: boolean, mine: number): Promise<void> {
    const offset = reset ? 0 : this.state.songs.length;
    if (!reset) {
      this.state.loadingMore = true;
    }
    try {
      const list = await fetchArtistSongs(this.state.artistId, offset, SONG_PAGE);
      if (mine !== this.seq) {
        return;
      }
      if (reset) {
        this.state.songs = list;
      } else {
        for (let i = 0; i < list.length; i++) {
          this.state.songs.push(list[i]);
        }
      }
      this.state.songs = this.state.songs.slice();
      this.state.hasMore = list.length >= SONG_PAGE;
      this.state.message = this.state.songs.length === 0 ? '没有取到单曲' : '';
    } catch (e) {
      if (mine === this.seq) {
        this.state.message = `单曲加载失败 ${(e as Error).message}`;
      }
    } finally {
      if (mine === this.seq) {
        this.state.loadingMore = false;
      }
    }
  }

  private async loadAlbums(reset: boolean, mine: number): Promise<void> {
    const offset = reset ? 0 : this.state.albums.length;
    if (!reset) {
      this.state.loadingMore = true;
    }
    try {
      const list = await fetchArtistAlbums(this.state.artistId, offset, ALBUM_PAGE);
      if (mine !== this.seq) {
        return;
      }
      if (reset) {
        this.state.albums = list;
      } else {
        for (let i = 0; i < list.length; i++) {
          this.state.albums.push(list[i]);
        }
      }
      this.state.albums = this.state.albums.slice();
      this.state.hasMore = list.length >= ALBUM_PAGE;
      this.state.message = this.state.albums.length === 0 ? '没有取到专辑' : '';
    } catch (e) {
      if (mine === this.seq) {
        this.state.message = `专辑加载失败 ${(e as Error).message}`;
      }
    } finally {
      if (mine === this.seq) {
        this.state.loadingMore = false;
      }
    }
  }

  private async loadMvs(reset: boolean, mine: number): Promise<void> {
    const offset = reset ? 0 : this.state.mvs.length;
    if (!reset) {
      this.state.loadingMore = true;
    }
    try {
      const list = await fetchArtistMvs(this.state.artistId, offset, MV_PAGE);
      if (mine !== this.seq) {
        return;
      }
      if (reset) {
        this.state.mvs = list;
      } else {
        for (let i = 0; i < list.length; i++) {
          this.state.mvs.push(list[i]);
        }
      }
      this.state.mvs = this.state.mvs.slice();
      this.state.hasMore = list.length >= MV_PAGE;
      this.state.message = this.state.mvs.length === 0 ? '这位歌手还没有 MV' : '';
    } catch (e) {
      if (mine === this.seq) {
        this.state.message = `MV 加载失败 ${(e as Error).message}`;
      }
    } finally {
      if (mine === this.seq) {
        this.state.loadingMore = false;
      }
    }
  }
}

export const neteaseArtist = new NeteaseArtistService();
