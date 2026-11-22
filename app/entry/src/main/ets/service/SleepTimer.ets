import { audioPlayer } from './AudioPlayer';
import { Logger } from '../common/Logger';

/** 可选的定时时长（分钟），0 表示关闭 */
const OPTIONS: number[] = [0, 15, 30, 60];

@ObservedV2
export class SleepState {
  /** 当前选中的分钟数，0 = 关闭 */
  @Trace minutes: number = 0;
  /** 剩余毫秒，展示倒计时用 */
  @Trace remainingMs: number = 0;
}

/**
 * 睡眠定时：到点暂停播放。
 *
 * 自己带一个 1 秒定时器，不依赖播放页是否打开——
 * 用户往往是设完定时就把页面收起来听歌。
 */
export class SleepTimer {
  private static instance: SleepTimer | null = null;
  readonly state: SleepState = new SleepState();
  private timer: number = -1;

  static getInstance(): SleepTimer {
    if (SleepTimer.instance === null) {
      SleepTimer.instance = new SleepTimer();
    }
    return SleepTimer.instance;
  }

  /** 关闭 → 15 → 30 → 60 → 关闭 循环切换 */
  cycle(): number {
    const idx = OPTIONS.indexOf(this.state.minutes);
    const next = OPTIONS[(idx + 1) % OPTIONS.length];
    this.setMinutes(next);
    return next;
  }

  setMinutes(minutes: number): void {
    this.stopTicker();
    this.state.minutes = minutes;
    if (minutes <= 0) {
      this.state.remainingMs = 0;
      Logger.i('睡眠定时已关闭');
      return;
    }
    this.state.remainingMs = minutes * 60000;
    Logger.i(`睡眠定时 ${minutes} 分钟`);
    this.timer = setInterval(() => {
      this.tick();
    }, 1000);
  }

  label(): string {
    if (this.state.minutes <= 0) {
      return '定时';
    }
    const totalSec = Math.max(0, Math.floor(this.state.remainingMs / 1000));
    const mm = Math.floor(totalSec / 60);
    const ss = totalSec % 60;
    const pad = ss < 10 ? `0${ss}` : `${ss}`;
    return `${mm}:${pad}`;
  }

  private tick(): void {
    this.state.remainingMs -= 1000;
    if (this.state.remainingMs > 0) {
      return;
    }
    this.stopTicker();
    this.state.minutes = 0;
    this.state.remainingMs = 0;
    Logger.i('睡眠定时到点，暂停播放');
    audioPlayer.pause();
  }

  private stopTicker(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }
}

export const sleepTimer: SleepTimer = SleepTimer.getInstance();
