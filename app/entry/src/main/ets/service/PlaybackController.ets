import { audioPlayer } from './AudioPlayer';
import { Song } from '../model/Song';
import { Logger } from '../common/Logger';
import { db } from './Db';
import { netease } from './NeteaseService';
import { NeteasePlayUrl } from './NeteaseApi';

/** 播放模式 */
export enum PlayMode {
  /** 列表循环 */
  SEQUENCE = 0,
  /** 随机 */
  SHUFFLE = 1,
  /** 单曲循环 */
  SINGLE = 2
}

@ObservedV2
export class PlayModeState {
  @Trace mode: PlayMode = PlayMode.SEQUENCE;
}

/**
 * 播放控制：持有队列，负责「点哪首放哪首」以及上下曲、播完自动下一首。
 */
export class PlaybackController {
  private static instance: PlaybackController | null = null;
  readonly modeState: PlayModeState = new PlayModeState();

  private queue: Song[] = [];
  private index: number = -1;
  private wired: boolean = false;

  static getInstance(): PlaybackController {
    if (PlaybackController.instance === null) {
      PlaybackController.instance = new PlaybackController();
    }
    return PlaybackController.instance;
  }

  /** 用当前列表作为播放队列 */
  setQueue(songs: Song[]): void {
    this.queue = songs;
    this.ensureWired();
  }

  getMode(): PlayMode {
    return this.modeState.mode;
  }

  setMode(mode: PlayMode): void {
    this.modeState.mode = mode;
  }

  /**
   * 恢复上次的曲目与进度（不自动播，等用户点播放）。
   * 曲目不在当前曲库里就返回 false，交给上层兜底。
   */
  restorePosition(path: string, positionMs: number, autoPlay: boolean = false): boolean {
    if (this.queue.length === 0 || path.length === 0) {
      return false;
    }
    for (let i = 0; i < this.queue.length; i++) {
      if (this.queue[i].path === path) {
        this.index = i;
        const song = this.queue[i];
        audioPlayer.state.artist = song.artist;
        audioPlayer.state.coverUrl = song.coverUrl;
        Logger.i(`恢复上次曲目 ${i} ${song.title} @${positionMs}ms`);
        if (song.isRemote()) {
          netease.playUrlOf(song).then((info) => {
            if (this.index !== i) {
              return;
            }
            if (!info.ok()) {
              audioPlayer.markFailed(song.title, song.path, '需要会员 / 版权受限，无法播放');
              return;
            }
            audioPlayer.open(info.url, song.title, autoPlay, positionMs, song.path,
              this.streamHeaders(info));
          });
          return true;
        }
        audioPlayer.open(song.path, song.title, autoPlay, positionMs);
        return true;
      }
    }
    return false;
  }

  /** B 站音源的 CDN 会校验 Referer，不带就 403；网易云的直链不需要 */
  private streamHeaders(info: NeteasePlayUrl): Record<string, string> | null {
    if (info.source !== 'bili') {
      return null;
    }
    return {
      'Referer': 'https://www.bilibili.com/',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        + 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
    };
  }

  /** 顺序 → 随机 → 单曲 循环切换 */
  cycleMode(): PlayMode {
    let next = PlayMode.SEQUENCE;
    if (this.modeState.mode === PlayMode.SEQUENCE) {
      next = PlayMode.SHUFFLE;
    } else if (this.modeState.mode === PlayMode.SHUFFLE) {
      next = PlayMode.SINGLE;
    }
    this.modeState.mode = next;
    Logger.i(`播放模式 -> ${next}`);
    return next;
  }

  async playIndex(index: number): Promise<void> {
    if (index < 0 || index >= this.queue.length) {
      return;
    }
    this.index = index;
    const song = this.queue[index];
    // 先更新“正在播放”的元信息：迷你播放器的封面与歌手靠这两个可观察字段刷新
    audioPlayer.state.artist = song.artist;
    audioPlayer.state.coverUrl = song.coverUrl;
    db.recordPlay(song.path, song.title);

    if (song.isRemote()) {
      // 解析地址要走网络，先把旧曲停下，免得到时候两个音源同时在响
      await audioPlayer.pause();
      netease.state.resolvingTitle = song.title;
      let info = await netease.playUrlOf(song);
      // 解析期间用户可能又切了别的歌，回来发现下标变了就别抢播
      if (this.index !== index) {
        netease.state.resolvingTitle = '';
        return;
      }
      netease.state.resolvingTitle = '';
      if (!info.ok()) {
        const msg = info.code === -110 ? '需要会员 / 版权受限，无法播放' : '拿不到播放地址';
        await audioPlayer.markFailed(song.title, song.path, msg);
        return;
      }
      await audioPlayer.open(info.url, song.title, true, 0, song.path, this.streamHeaders(info));
      song.quality = info.qualityLabel();
      return;
    }

    await audioPlayer.open(song.path, song.title, true);
  }

  /** 根据路径播放（列表点击用，顺带校准队列索引） */
  playSong(song: Song, from: Song[]): void {
    const list: Song[] = from.length > 0 ? from : [song];
    this.setQueue(list);
    for (let i = 0; i < this.queue.length; i++) {
      if (this.queue[i].path === song.path) {
        this.playIndex(i);
        return;
      }
    }
    // 列表刚变过、这首已经不在里面了，退化成单曲播放，总比什么都不发生好
    this.setQueue([song]);
    this.playIndex(0);
  }

  next(): void {
    if (this.queue.length === 0) {
      return;
    }
    let target = 0;
    if (this.modeState.mode === PlayMode.SHUFFLE) {
      target = this.randomIndex();
    } else {
      target = this.index < 0 ? 0 : (this.index + 1) % this.queue.length;
    }
    this.playIndex(target);
  }

  previous(): void {
    if (this.queue.length === 0) {
      return;
    }
    let target = 0;
    if (this.modeState.mode === PlayMode.SHUFFLE) {
      target = this.randomIndex();
    } else {
      target = this.index <= 0 ? this.queue.length - 1 : this.index - 1;
    }
    this.playIndex(target);
  }

  currentIndex(): number {
    return this.index;
  }

  /** 当前队列副本，给队列面板用 */
  getQueue(): Song[] {
    return this.queue.slice();
  }

  queueLength(): number {
    return this.queue.length;
  }

  /** 清空队列并停掉播放，播放条会随之隐藏 */
  async clearQueue(): Promise<void> {
    this.queue = [];
    this.index = -1;
    await audioPlayer.release();
    Logger.i('队列已清空');
  }

  /** 当前曲目对象，AVSession 推元数据要用 */
  currentSong(): Song | null {
    if (this.index < 0 || this.index >= this.queue.length) {
      return null;
    }
    return this.queue[this.index];
  }

  private randomIndex(): number {
    if (this.queue.length <= 1) {
      return 0;
    }
    let candidate = Math.floor(Math.random() * this.queue.length);
    if (candidate === this.index) {
      candidate = (candidate + 1) % this.queue.length;
    }
    return candidate;
  }

  private ensureWired(): void {
    if (this.wired) {
      return;
    }
    this.wired = true;
    audioPlayer.onCompleted = () => {
      if (this.modeState.mode === PlayMode.SINGLE) {
        Logger.i('单曲循环，重播当前曲');
        audioPlayer.seek(0).then(() => {
          audioPlayer.play();
        });
        return;
      }
      Logger.i('自然播完，自动下一首');
      this.next();
    };
  }
}

export const playback: PlaybackController = PlaybackController.getInstance();
