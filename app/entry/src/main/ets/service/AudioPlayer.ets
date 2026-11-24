import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Logger } from '../common/Logger';

/**
 * 播放器对外暴露的可观察状态。
 * V2 状态管理：@Trace 的字段变更会驱动 UI 刷新。
 */
@ObservedV2
export class PlayerState {
  /** 当前曲目显示名 */
  @Trace title: string = '';
  /** 当前曲目歌手，迷你播放器用 */
  @Trace artist: string = '';
  /** 当前曲目封面：在线曲目有网络封面，本地曲目为空、走缩略图 */
  @Trace coverUrl: string = '';
  /** 当前曲目路径，列表里用来高亮 */
  @Trace currentPath: string = '';
  /** 是否正在出声 */
  @Trace isPlaying: boolean = false;
  /** 打开文件 → prepare 完成之间为 true */
  @Trace isLoading: boolean = false;
  /** 当前进度（毫秒） */
  @Trace positionMs: number = 0;
  /** 总时长（毫秒），未解析出来前为 0 */
  @Trace durationMs: number = 0;
  /** 播放器内部状态字符串，调试用 */
  @Trace avState: string = 'idle';
  /** 播放倍速 */
  @Trace speed: number = 1;
  /** 出错信息，空串表示正常 */
  @Trace errorMsg: string = '';
}

/**
 * AVPlayer 的一层薄封装。
 *
 * 踩坑记录：
 * 1. 本地点播只接受 fd，不接受 file path，所以必须 fs.open 拿 fd 再塞 fdSrc
 * 2. fdSrc 赋值后状态机进入 initialized，此时必须调用 prepare()
 * 3. prepare 完成（prepared）才能拿 player.duration，也只有这时才能 play()
 * 4. release() 之后实例不可复用，必须重新 createAVPlayer()
 */
export class AudioPlayer {
  private static instance: AudioPlayer | null = null;
  readonly state: PlayerState = new PlayerState();

  /** 自然播完一整个文件时回调，用来做自动下一首 */
  onCompleted: (() => void) | null = null;

  private player: media.AVPlayer | null = null;
  private curFd: number = -1;
  private pendingAutoPlay: boolean = false;
  private pendingSeekMs: number = 0;
  /** 可选倍速，和 PlaybackSpeed 枚举一一对应 */
  private static readonly SPEEDS: number[] = [0.5, 0.75, 1, 1.25, 1.75, 2];
  /** seek 之后一小段时间内忽略 timeUpdate，避免被旧位置覆盖 */
  private seekGuardUntil: number = 0;

  static getInstance(): AudioPlayer {
    if (AudioPlayer.instance === null) {
      AudioPlayer.instance = new AudioPlayer();
    }
    return AudioPlayer.instance;
  }

  /**
   * 打开一个音频源。
   * @param source 本地文件路径，或 http(s) 直链
   * @param autoPlay 解析完是否立刻播
   * @param startPositionMs 从第几毫秒开始（恢复上次进度用）
   * @param identity 列表里用来高亮的稳定标识；在线曲目传 netease://id，
   *                 因为真实播放地址每次都会变，不能拿它当身份
   */
  async open(source: string, displayName: string, autoPlay: boolean = true,
    startPositionMs: number = 0, identity: string = '',
    headers: Record<string, string> | null = null): Promise<void> {
    Logger.i(`open: ${source}`);
    this.state.errorMsg = '';
    this.state.isLoading = true;
    this.state.title = displayName;
    this.state.currentPath = identity.length > 0 ? identity : source;
    this.state.positionMs = 0;
    this.state.durationMs = 0;
    this.pendingAutoPlay = autoPlay;
    this.pendingSeekMs = startPositionMs;

    try {
      await this.releasePlayer();

      const p = await media.createAVPlayer();
      this.player = p;
      this.bindEvents(p);

      if (source.startsWith('http://') || source.startsWith('https://')) {
        // 网络流：直接赋 url，状态机同样会走到 initialized。
        // 有些 CDN（比如 B 站）会校验 Referer，不带就直接 403，所以支持自定义请求头。
        if (headers !== null) {
          const src = media.createMediaSourceWithUrl(source, headers);
          await p.setMediaSource(src);
        } else {
          p.url = source;
        }
        return;
      }

      const file = fs.openSync(source, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      this.curFd = file.fd;
      Logger.i(`fd=${file.fd} size=${stat.size}`);

      // 赋值 fdSrc 会驱动状态机 idle -> initialized
      p.fdSrc = { fd: this.curFd, offset: 0, length: stat.size };
    } catch (e) {
      const err = e as BusinessError;
      this.fail(`打开失败 ${err.code}: ${err.message}`);
    }
  }

  /** 播放 / 暂停切换 */
  async toggle(): Promise<void> {
    if (this.state.isPlaying) {
      await this.pause();
    } else {
      await this.play();
    }
  }

  /** 明确起播（AVSession 遥控用，不能靠 toggle） */
  async play(): Promise<void> {
    const p = this.player;
    if (p === null) {
      return;
    }
    if (this.state.avState !== 'prepared' && this.state.avState !== 'paused'
      && this.state.avState !== 'completed') {
      Logger.w(`play 忽略，当前状态 ${this.state.avState}`);
      return;
    }
    try {
      await p.play();
    } catch (e) {
      const err = e as BusinessError;
      this.fail(`play 失败 ${err.code}: ${err.message}`);
    }
  }

  /** 明确暂停 */
  async pause(): Promise<void> {
    const p = this.player;
    if (p === null) {
      return;
    }
    if (this.state.avState !== 'playing') {
      return;
    }
    try {
      await p.pause();
    } catch (e) {
      const err = e as BusinessError;
      this.fail(`pause 失败 ${err.code}: ${err.message}`);
    }
  }

  /** 拖动进度 */
  async seek(ms: number): Promise<void> {
    const p = this.player;
    if (p === null) {
      return;
    }
    if (this.state.avState !== 'prepared' && this.state.avState !== 'playing'
      && this.state.avState !== 'paused' && this.state.avState !== 'completed') {
      return;
    }
    try {
      const target = Math.max(0, Math.round(ms));
      this.seekGuardUntil = Date.now() + 400;
      p.seek(target);
      // 暂停状态下 seek 不触发 timeUpdate，播放中则会迟到，
      // 所以自己先同步一次，避免进度条和歌词停在旧位置。
      this.state.positionMs = target;
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`seek 失败 ${err.code}: ${err.message}`);
    }
  }

  /**
   * 无法起播时（版权受限、地址解析失败）在播放器状态里留个记号。
   * 先把旧播放器彻底释放，否则它还会继续吐 timeUpdate，
   * 把上一首的进度写到这首失败曲目上。
   */
  async markFailed(title: string, identity: string, message: string): Promise<void> {
    await this.releasePlayer();
    this.state.title = title;
    this.state.currentPath = identity;
    this.state.isPlaying = false;
    this.state.isLoading = false;
    this.state.positionMs = 0;
    this.state.durationMs = 0;
    this.state.avState = 'idle';
    this.state.errorMsg = message;
    Logger.w(`起播失败 ${title}: ${message}`);
  }

  /** 释放播放器与文件句柄 */
  async release(): Promise<void> {    await this.releasePlayer();
    this.state.title = '';
    this.state.currentPath = '';
    this.state.isPlaying = false;
    this.state.positionMs = 0;
    this.state.durationMs = 0;
    this.state.avState = 'idle';
  }

  private async releasePlayer(): Promise<void> {
    const p = this.player;
    this.player = null;
    if (p !== null) {
      try {
        p.off('stateChange');
        p.off('timeUpdate');
        p.off('durationUpdate');
        p.off('error');
        await p.release();
      } catch (e) {
        const err = e as BusinessError;
        Logger.w(`release 播放器异常 ${err.code}: ${err.message}`);
      }
    }
    if (this.curFd >= 0) {
      try {
        fs.closeSync(this.curFd);
      } catch (e) {
        const err = e as BusinessError;
        Logger.w(`关闭 fd 异常 ${err.code}: ${err.message}`);
      }
      this.curFd = -1;
    }
  }

  private bindEvents(p: media.AVPlayer): void {
    p.on('stateChange', (state: media.AVPlayerState) => {
      Logger.i(`stateChange: ${state}`);
      this.state.avState = state;
      switch (state) {
        case 'initialized':
          // 必须在这一步 prepare，否则状态机卡住
          p.prepare().catch((e: BusinessError) => {
            this.fail(`prepare 失败 ${e.code}: ${e.message}`);
          });
          break;
        case 'prepared':
          this.state.isLoading = false;
          this.state.durationMs = p.duration;
          this.afterPrepared(p);
          break;
        case 'playing':
          this.state.isPlaying = true;
          this.state.isLoading = false;
          break;
        case 'paused':
        case 'completed':
          this.state.isPlaying = false;
          if (state === 'completed') {
            this.state.positionMs = this.state.durationMs;
            const cb = this.onCompleted;
            if (cb !== null) {
              // 不能在这个回调里直接重建播放器，跳出当前状态机再回调
              setTimeout(() => {
                cb();
              }, 0);
            }
          }
          break;
        case 'stopped':
        case 'released':
          this.state.isPlaying = false;
          break;
        case 'error':
          this.state.isPlaying = false;
          this.state.isLoading = false;
          break;
        default:
          break;
      }
    });

    p.on('timeUpdate', (time: number) => {
      if (Date.now() < this.seekGuardUntil) {
        return;
      }
      this.state.positionMs = time;
    });

    p.on('durationUpdate', (duration: number) => {
      this.state.durationMs = duration;
    });

    p.on('error', (err: BusinessError) => {
      this.fail(`AVPlayer 错误 ${err.code}: ${err.message}`);
    });
  }

  /** prepared 之后：先跳到目标位置，再决定要不要起播 */
  private afterPrepared(p: media.AVPlayer): void {
    const seekTo = this.pendingSeekMs;
    this.pendingSeekMs = 0;
    if (seekTo > 0 && seekTo < p.duration) {
      // AVPlayer.seek 是同步返回 void，不返回 Promise
      try {
        p.seek(seekTo);
        this.state.positionMs = seekTo;
      } catch (e) {
        const err = e as BusinessError;
        Logger.w(`恢复进度失败 ${err.code}，从头开始`);
      }
    }
    this.applySpeed();
    if (this.pendingAutoPlay) {
      this.play();
    }
  }

  /** 切倍速：0.5 → 0.75 → 1 → 1.25 → 1.75 → 2 → 0.5 */
  cycleSpeed(): number {
    const list = AudioPlayer.SPEEDS;
    let idx = list.indexOf(this.state.speed);
    if (idx < 0) {
      idx = 2;
    }
    const next = list[(idx + 1) % list.length];
    this.setSpeed(next);
    return next;
  }

  setSpeed(speed: number): void {
    this.state.speed = speed;
    this.applySpeed();
  }

  private applySpeed(): void {
    const p = this.player;
    if (p === null) {
      return;
    }
    let mode = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    if (this.state.speed === 0.5) {
      mode = media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    } else if (this.state.speed === 0.75) {
      mode = media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    } else if (this.state.speed === 1.25) {
      mode = media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    } else if (this.state.speed === 1.75) {
      mode = media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    } else if (this.state.speed === 2) {
      mode = media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
    }
    try {
      p.setSpeed(mode);
      Logger.i(`倍速 ${this.state.speed}x`);
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`设置倍速失败 ${err.code}`);
    }
  }

  private fail(msg: string): void {
    Logger.e(msg);
    this.state.errorMsg = msg;
    this.state.isLoading = false;
    this.state.isPlaying = false;
  }
}

export const audioPlayer: AudioPlayer = AudioPlayer.getInstance();
