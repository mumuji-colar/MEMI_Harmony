import { avSession } from '@kit.AVSessionKit';
import { common } from '@kit.AbilityKit';
import { wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { audioPlayer } from './AudioPlayer';
import { playback, PlayMode } from './PlaybackController';
import { Song } from '../model/Song';
import { Logger } from '../common/Logger';
import { persist } from './PersistService';
import { cover } from './CoverService';
import { lyric } from './LyricService';

// 兜底值；正常从 context.abilityInfo 读，改 bundleName 时不用跟着改这里
const BUNDLE_NAME: string = 'com.mmc.merimusicplayer';
const ABILITY_NAME: string = 'EntryAbility';
const SESSION_TAG: string = 'memi_audio';

/**
 * 媒体会话 + 后台长时任务。
 *
 * 两件事必须一起做：
 * 1. AVSession：把播放状态交给系统，通知栏/锁屏/蓝牙耳机才有控制入口
 * 2. backgroundTaskManager 的 AUDIO_PLAYBACK 长时任务：息屏后进程不被回收
 *
 * 官方说明：AUDIO_PLAYBACK 任务如果没有连 AVSession，通知栏会出现一条
 * 后台任务通知；连上 AVSession 后由 AVSession 接管通知，不会重复弹。
 *
 * 状态同步用 1 秒一次的轮询，而不是在 AudioPlayer 里塞一堆回调——
 * 播放器不知道 AVSession 存在，解耦更干净，代价是进度最多滞后 1 秒。
 */
export class MediaSessionService {
  private static instance: MediaSessionService | null = null;

  private session: avSession.AVSession | null = null;
  private ctx: common.UIAbilityContext | null = null;
  private timer: number = -1;
  private lastAssetId: string = '';
  private bgRunning: boolean = false;
  private tickCount: number = 0;
  /** 整段 LRC 与封面缓存：setAVMetadata 是整对象替换，得自己留着才能逐次重发 */
  private cachedLrc: string = '';
  private cachedImage: image.PixelMap | string | null = null;
  private lastLyricIndex: number = -2;
  private lastLyricCount: number = -1;
  private lastCoverToken: string = '';

  static getInstance(): MediaSessionService {
    if (MediaSessionService.instance === null) {
      MediaSessionService.instance = new MediaSessionService();
    }
    return MediaSessionService.instance;
  }

  async init(ctx: common.UIAbilityContext): Promise<void> {
    if (this.session !== null) {
      return;
    }
    this.ctx = ctx;
    try {
      const s = await avSession.createAVSession(ctx, SESSION_TAG, 'audio');
      this.session = s;
      this.bindRemoteControls(s);
      await s.activate();
      this.startTicker();
      Logger.i('AVSession 创建并激活成功');
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`AVSession 初始化失败 ${err.code}: ${err.message}`);
    }
  }

  /** 页面退出时别销毁会话——后台播放还要用它 */
  async destroy(): Promise<void> {
    this.stopTicker();
    await this.stopBackground();
    const s = this.session;
    this.session = null;
    if (s !== null) {
      try {
        await s.destroy();
      } catch (e) {
        const err = e as BusinessError;
        Logger.w(`destroy session 失败 ${err.code}`);
      }
    }
  }

  /** 切后台/退出前立刻落盘，避免丢掉最后一小段进度 */
  savePlaybackNow(): void {
    const c = this.ctx;
    const st = audioPlayer.state;
    if (c === null || st.currentPath.length === 0) {
      return;
    }
    persist.savePlayback(c, st.currentPath, st.positionMs, playback.getMode(), playback.currentSong());
  }

  private bindRemoteControls(s: avSession.AVSession): void {
    s.on('play', () => {
      Logger.i('遥控：play');
      audioPlayer.play();
    });
    s.on('pause', () => {
      Logger.i('遥控：pause');
      audioPlayer.pause();
    });
    s.on('stop', () => {
      Logger.i('遥控：stop');
      audioPlayer.pause();
    });
    s.on('playNext', () => {
      Logger.i('遥控：playNext');
      playback.next();
    });
    s.on('playPrevious', () => {
      Logger.i('遥控：playPrevious');
      playback.previous();
    });
    s.on('seek', (time: number) => {
      Logger.i(`遥控：seek ${time}`);
      audioPlayer.seek(time);
    });
  }

  private startTicker(): void {
    if (this.timer >= 0) {
      return;
    }
    this.timer = setInterval(() => {
      this.tick();
    }, 1000);
    this.tick();
  }

  private stopTicker(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private tick(): void {
    const s = this.session;
    if (s === null) {
      return;
    }
    const st = audioPlayer.state;

    if (st.currentPath.length > 0 && st.currentPath !== this.lastAssetId) {
      this.lastAssetId = st.currentPath;
      this.lastCoverToken = '';
      this.lastLyricCount = -1;
      this.lastLyricIndex = -2;
      this.cachedImage = null;
      this.cachedLrc = '';
      this.pushMetadata(true);
    }

    // 后台也要把歌词读出来并推进当前行，否则播控中心一直是「无歌词」
    if (st.currentPath.length > 0) {
      lyric.syncTo(playback.currentSong(), st.positionMs);
    }

    // 歌词解析完成（行数变化）：整段 LRC 要重发一次
    if (lyric.state.lines.length !== this.lastLyricCount && this.lastAssetId.length > 0) {
      this.lastLyricCount = lyric.state.lines.length;
      this.lastLyricIndex = lyric.state.currentIndex;
      this.pushMetadata(true);
    }

    // 歌词行变了：只更新单行歌词（整段 LRC 不必重发）
    if (lyric.state.currentIndex !== this.lastLyricIndex && this.lastAssetId.length > 0) {
      this.lastLyricIndex = lyric.state.currentIndex;
      this.pushMetadata(false);
    }

    // 本地封面是异步解码的，解出来之后要补一次，否则播控中心一直是空的
    const coverToken = `${cover.state.path}|${cover.state.cover === null ? '0' : '1'}`;
    if (coverToken !== this.lastCoverToken && cover.state.path === st.currentPath && st.currentPath.length > 0) {
      this.lastCoverToken = coverToken;
      this.pushMetadata(false);
    }

    let state: avSession.PlaybackState = avSession.PlaybackState.PLAYBACK_STATE_STOP;
    if (st.isPlaying) {
      state = avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    } else if (st.avState === 'paused') {
      state = avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
    } else if (st.avState === 'prepared' || st.isLoading) {
      state = avSession.PlaybackState.PLAYBACK_STATE_PREPARE;
    }

    const pb: avSession.AVPlaybackState = {
      state: state,
      position: {
        elapsedTime: st.positionMs > 0 ? st.positionMs : 0,
        updateTime: Date.now()
      },
      loopMode: this.mapLoopMode(playback.getMode())
    };
    // speed=0 和 duration=0 都会被判成非法参数（401），只在有效时才带
    if (st.isPlaying) {
      pb.speed = 1;
    }
    if (st.durationMs > 0) {
      pb.duration = st.durationMs;
    }
    s.setAVPlaybackState(pb).catch((e: BusinessError) => {
      Logger.w(`setAVPlaybackState 失败 ${e.code}: ${e.message}`);
    });

    // 每 5 秒落一次盘，重启后能接着上次听
    this.tickCount++;
    if (this.tickCount % 5 === 0 && st.currentPath.length > 0 && this.ctx !== null) {
      persist.savePlayback(this.ctx, st.currentPath, st.positionMs, playback.getMode(), playback.currentSong());
    }

    // 在放就保证长时任务在跑，停了就撤掉，避免通知栏留一条无用通知
    if (st.isPlaying) {
      this.ensureBackground();
    } else {
      this.stopBackground();
    }
  }

  private mapLoopMode(mode: PlayMode): avSession.LoopMode {
    if (mode === PlayMode.SINGLE) {
      return avSession.LoopMode.LOOP_MODE_SINGLE;
    }
    if (mode === PlayMode.SHUFFLE) {
      return avSession.LoopMode.LOOP_MODE_SHUFFLE;
    }
    return avSession.LoopMode.LOOP_MODE_LIST;
  }

  /**
   * 推元数据。
   * @param full 换曲时传 true，会把整段 LRC 一起发过去（系统自己按进度滚），
   *             平时行变化只更新 singleLyricText
   */
  private pushMetadata(full: boolean): void {
    const s = this.session;
    if (s === null) {
      return;
    }
    const song = playback.currentSong();
    const st = audioPlayer.state;

    const freshImage = this.coverFor(song);
    if (freshImage !== undefined) {
      this.cachedImage = freshImage;
    }
    if (full) {
      this.cachedLrc = this.buildLrc();
    }

    // 注意：不能把没值的字段赋成 undefined，系统侧会报 401（get metaData failed），
    // 所以每次都重建对象，只放真正有值的字段。
    const meta: avSession.AVMetadata = {
      assetId: st.currentPath,
      title: song !== null ? song.title : st.title,
      artist: song !== null ? song.artist : '',
      album: song !== null ? song.album : ''
    };
    if (st.durationMs > 0) {
      meta.duration = st.durationMs;
    }
    if (this.cachedImage !== null) {
      meta.mediaImage = this.cachedImage;
    }
    if (this.cachedLrc.length > 0) {
      meta.lyric = this.cachedLrc;
    }
    const line = this.currentLyricText();
    if (line.length > 0) {
      meta.singleLyricText = line;
    }
    s.setAVMetadata(meta).catch((e: BusinessError) => {
      Logger.w(`setAVMetadata 失败 ${e.code}: ${e.message} | image=${meta.mediaImage === undefined ? 'no'
        : 'yes'} lyric=${(meta.lyric === undefined ? 0 : meta.lyric.length)} single=${(meta.singleLyricText === undefined
        ? 0 : meta.singleLyricText.length)}`);
    });
  }

  /** 播控中心/胶囊的封面：在线曲目直接给 https 地址，本地曲目给解码好的 PixelMap */
  private coverFor(song: Song | null): image.PixelMap | string | undefined {
    if (song !== null && song.isRemote()) {
      return song.coverUrl.length > 0 ? song.coverUrl : undefined;
    }
    if (song !== null && cover.state.path === song.path && cover.state.cover !== null) {
      return cover.state.cover;
    }
    return undefined;
  }

  /** 把解析好的歌词还原成标准 LRC，交给系统做滚动 */
  private buildLrc(): string {
    const lines = lyric.state.lines;
    if (lines.length === 0) {
      return '';
    }
    let out = '';
    const max = Math.min(lines.length, 600);
    for (let i = 0; i < max; i++) {
      const t = lines[i].timeMs;
      if (t < 0) {
        continue;
      }
      const m = Math.floor(t / 60000);
      const sec = Math.floor((t % 60000) / 1000);
      const cs = Math.floor((t % 1000) / 10);
      out += `[${this.pad2(m)}:${this.pad2(sec)}.${this.pad2(cs)}]${lines[i].text}\n`;
    }
    return out;
  }

  private currentLyricText(): string {
    const idx = lyric.state.currentIndex;
    const lines = lyric.state.lines;
    if (idx < 0 || idx >= lines.length) {
      return '';
    }
    return lines[idx].text;
  }

  private pad2(v: number): string {
    return v < 10 ? `0${v}` : `${v}`;
  }

  private async ensureBackground(): Promise<void> {
    if (this.bgRunning) {
      return;
    }
    const c = this.ctx;
    if (c === null) {
      return;
    }
    try {
      // 从上下文读当前包名/ Ability 名：改 bundleName 后不会指向旧应用
      const bundle = c.abilityInfo.bundleName.length > 0 ? c.abilityInfo.bundleName : BUNDLE_NAME;
      const ability = c.abilityInfo.name.length > 0 ? c.abilityInfo.name : ABILITY_NAME;
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: bundle,
            abilityName: ability
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(
        c, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      this.bgRunning = true;
      Logger.i('长时任务 audioPlayback 已申请');
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`申请长时任务失败 ${err.code}: ${err.message}`);
    }
  }

  private async stopBackground(): Promise<void> {
    if (!this.bgRunning) {
      return;
    }
    const c = this.ctx;
    if (c === null) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(c);
      this.bgRunning = false;
      Logger.i('长时任务已释放');
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`释放长时任务失败 ${err.code}: ${err.message}`);
    }
  }
}

export const mediaSession: MediaSessionService = MediaSessionService.getInstance();
