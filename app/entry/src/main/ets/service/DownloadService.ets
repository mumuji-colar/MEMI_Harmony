import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Song } from '../model/Song';
import { DownloadTask, DownloadStatus } from '../model/DownloadTask';
import { db } from './Db';
import { settings } from './SettingsService';
import { resolvePlayUrl, fetchLyric, NeteaseLyric } from './NeteaseApi';
import { Logger } from '../common/Logger';

/** 同时下载几个 */
const MAX_ACTIVE: number = 2;
/** 超过这么久没有新数据就认为卡死 */
const IDLE_TIMEOUT_MS: number = 60000;

const UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
  + 'Chrome/124.0 Safari/537.36';

/** 一次进行中的下载 */
class ActiveDownload {
  task: DownloadTask;
  req: http.HttpRequest | null = null;
  file: fs.File | null = null;
  canceled: boolean = false;
  /** 被删除：结果不要再写回数据库 */
  removed: boolean = false;
  lastDataAt: number = 0;

  constructor(task: DownloadTask) {
    this.task = task;
    this.lastDataAt = Date.now();
  }
}

@ObservedV2
export class DownloadState {
  @Trace tasks: DownloadTask[] = [];
  /** 已完成的曲目，按任务顺序 */
  @Trace doneSongs: Song[] = [];
  @Trace inited: boolean = false;
  @Trace message: string = '';
  /** 已下载总占用字节 */
  @Trace totalBytes: number = 0;
  @Trace activeCount: number = 0;
  @Trace version: number = 0;
}

/**
 * 下载管理。
 *
 * 用 http 的流式接口自己写文件，而不是 request.agent：
 * - 需要带 Cookie/Referer 拿会员码率，agent 的自定义头支持不如直接请求直观
 * - 需要精确控制断点续传（resumeFrom）与沙箱路径
 *
 * 代价是应用被杀后不会继续下载：重启时把「下载中」改成「已暂停」，
 * 用户点继续会从已有字节处续传。
 */
export class DownloadService {
  readonly state: DownloadState = new DownloadState();
  private ctx: common.UIAbilityContext | null = null;
  private dir: string = '';
  private active: ActiveDownload[] = [];
  private pumping: boolean = false;
  /** 本次会话里已经尝试过补歌词的曲目，避免反复请求 */
  private lyricTried: Set<string> = new Set<string>();

  async init(ctx: common.UIAbilityContext): Promise<void> {
    if (this.state.inited) {
      return;
    }
    this.ctx = ctx;
    this.dir = `${ctx.filesDir}/downloads`;
    try {
      fs.mkdirSync(this.dir, true);
    } catch (e) {
      // 已存在
    }
    const list = await db.loadDownloadTasks();
    for (let i = 0; i < list.length; i++) {
      const t = list[i];
      if (t.status === DownloadStatus.DOWNLOADING) {
        t.status = DownloadStatus.PAUSED;
      }
      const size = this.fileSize(t.filePath);
      if (size > 0) {
        t.downloadedBytes = size;
        if (t.totalBytes < size) {
          t.totalBytes = size;
        }
      }
      if (t.status === DownloadStatus.DONE && size <= 0) {
        t.status = DownloadStatus.FAILED;
        t.error = '文件已丢失';
      }
      db.saveDownloadTask(t);
    }
    this.state.tasks = list;
    this.state.inited = true;
    this.refreshCounters();
    Logger.i(`下载任务已恢复 ${list.length} 个`);
    this.pump();
  }

  /** 队列里有没有这首歌 */
  find(songPath: string): DownloadTask | null {
    for (let i = 0; i < this.state.tasks.length; i++) {
      if (this.state.tasks[i].songPath === songPath) {
        return this.state.tasks[i];
      }
    }
    return null;
  }

  isDownloaded(songPath: string): boolean {
    const t = this.find(songPath);
    return t !== null && t.status === DownloadStatus.DONE;
  }

  /** 加入下载队列 */
  async enqueue(song: Song): Promise<boolean> {
    if (!song.isRemote() || song.remoteId <= 0) {
      this.state.message = '只有在线曲目可以下载';
      return false;
    }
    const exist = this.find(song.path);
    if (exist !== null) {
      this.state.message = exist.status === DownloadStatus.DONE ? '这首歌已经下载过了' : '已经在下载列表里';
      return false;
    }
    const level = settings.onlineLevel();
    this.state.message = '正在解析下载地址…';
    try {
      const info = await resolvePlayUrl(song.remoteId, level);
      if (!info.ok()) {
        this.state.message = info.code === -110 ? '需要会员 / 版权受限，无法下载' : '拿不到下载地址';
        return false;
      }
      const ext = info.type.length > 0 ? info.type : 'mp3';
      const task = new DownloadTask();
      task.songPath = song.path;
      task.remoteId = song.remoteId;
      task.title = song.title;
      task.artist = song.artist;
      task.album = song.album;
      task.artistId = song.artistId;
      task.durationMs = song.durationMs;
      task.coverUrl = song.coverUrl;
      task.quality = settings.onlineQualityLabel();
      task.level = level;
      task.filePath = `${this.dir}/${song.remoteId}_${this.safeName(song.title)}.${ext}`;
      task.totalBytes = info.size;
      task.downloadedBytes = 0;
      task.status = DownloadStatus.WAITING;
      task.createdAt = Date.now();
      this.state.tasks.unshift(task);
      this.state.tasks = this.state.tasks.slice();
      await db.saveDownloadTask(task);
      this.state.message = `已加入下载：${song.title}`;
      this.refreshCounters();
      this.pump();
      return true;
    } catch (e) {
      this.state.message = `下载失败 ${(e as Error).message}`;
      Logger.w(`加入下载失败 ${(e as Error).message}`);
      return false;
    }
  }

  pause(task: DownloadTask): void {
    const active = this.activeOf(task.songPath);
    if (active !== null) {
      active.canceled = true;
      try {
        active.req?.destroy();
      } catch (e) {
        // 忽略
      }
    }
    if (task.status !== DownloadStatus.DONE) {
      task.status = DownloadStatus.PAUSED;
      db.saveDownloadTask(task);
    }
    this.refreshCounters();
  }

  resume(task: DownloadTask): void {
    if (task.status === DownloadStatus.DONE) {
      return;
    }
    task.status = DownloadStatus.WAITING;
    task.error = '';
    db.saveDownloadTask(task);
    this.refreshCounters();
    this.pump();
  }

  /** 删除任务与文件 */
  async remove(task: DownloadTask): Promise<void> {
    Logger.i(`删除下载 ${task.title}`);
    const active = this.activeOf(task.songPath);
    if (active !== null) {
      active.removed = true;
      active.canceled = true;
      try {
        active.req?.destroy();
      } catch (e) {
        // 忽略
      }
    }
    try {
      if (this.fileSize(task.filePath) > 0) {
        fs.unlinkSync(task.filePath);
      }
    } catch (e) {
      Logger.w(`删除文件失败 ${(e as Error).message}`);
    }
    this.removeLyricFiles(task);
    await db.deleteDownloadTask(task.songPath);
    const next: DownloadTask[] = [];
    for (let i = 0; i < this.state.tasks.length; i++) {
      if (this.state.tasks[i].songPath !== task.songPath) {
        next.push(this.state.tasks[i]);
      }
    }
    this.state.tasks = next;
    this.refreshCounters();
    this.pump();
  }

  /** 清空已完成的下载 */
  async clearDone(): Promise<void> {
    const done: DownloadTask[] = [];
    for (let i = 0; i < this.state.tasks.length; i++) {
      if (this.state.tasks[i].status === DownloadStatus.DONE) {
        done.push(this.state.tasks[i]);
      }
    }
    for (let i = 0; i < done.length; i++) {
      await this.remove(done[i]);
    }
    this.state.message = '已清空下载';
  }

  /** 给已下载但还没有歌词文件的曲目补歌词，串行做，避免一次打太多请求 */
  async ensureLyrics(): Promise<void> {
    for (let i = 0; i < this.state.tasks.length; i++) {
      const t = this.state.tasks[i];
      if (t.status === DownloadStatus.DONE) {
        await this.saveLyrics(t);
      }
    }
  }

  /** 暂停全部 */
  pauseAll(): void {
    for (let i = 0; i < this.state.tasks.length; i++) {
      const t = this.state.tasks[i];
      if (t.status === DownloadStatus.DOWNLOADING || t.status === DownloadStatus.WAITING) {
        this.pause(t);
      }
    }
  }

  /** 继续全部未完成的 */
  resumeAll(): void {
    for (let i = 0; i < this.state.tasks.length; i++) {
      const t = this.state.tasks[i];
      if (t.status === DownloadStatus.PAUSED || t.status === DownloadStatus.FAILED) {
        t.status = DownloadStatus.WAITING;
        t.error = '';
        db.saveDownloadTask(t);
      }
    }
    this.refreshCounters();
    this.pump();
  }

  // ---------- 内部 ----------

  private pump(): void {
    if (this.pumping) {
      return;
    }
    this.pumping = true;
    try {
      while (this.active.length < MAX_ACTIVE) {
        let next: DownloadTask | null = null;
        for (let i = 0; i < this.state.tasks.length; i++) {
          if (this.state.tasks[i].status === DownloadStatus.WAITING) {
            next = this.state.tasks[i];
            break;
          }
        }
        if (next === null) {
          break;
        }
        this.run(next);
      }
    } finally {
      this.pumping = false;
    }
  }

  private async run(task: DownloadTask): Promise<void> {
    const active = new ActiveDownload(task);
    this.active.push(active);
    task.status = DownloadStatus.DOWNLOADING;
    task.error = '';
    this.refreshCounters();
    db.saveDownloadTask(task);

    try {
      const level = task.level.length > 0 ? task.level : settings.onlineLevel();
      const info = await resolvePlayUrl(task.remoteId, level);
      if (active.canceled || active.removed) {
        return;
      }
      if (!info.ok()) {
        throw new Error(info.code === -110 ? '需要会员 / 版权受限' : '拿不到下载地址');
      }
      if (task.totalBytes <= 0 && info.size > 0) {
        task.totalBytes = info.size;
      }

      const base = this.fileSize(task.filePath);
      task.downloadedBytes = base;
      Logger.i(`下载开始 ${task.title}，已有 ${formatBytes(base)}${base > 0 ? '，尝试续传' : ''}`);
      const file = fs.openSync(task.filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      active.file = file;
      let written = base;

      const req = http.createHttp();
      active.req = req;
      let lastPush: number = Date.now();

      req.on('dataReceive', (chunk: ArrayBuffer) => {
        if (active.canceled || active.removed) {
          return;
        }
        try {
          fs.writeSync(file.fd, chunk, { offset: written });
          written += chunk.byteLength;
          active.lastDataAt = Date.now();
          // 控制 UI 刷新频率，1KB 一次会明显掉帧
          if (Date.now() - lastPush >= 200) {
            lastPush = Date.now();
            task.downloadedBytes = written;
          }
        } catch (e) {
          Logger.w(`写文件失败 ${(e as Error).message}`);
        }
      });

      req.on('dataReceiveProgress', (info2: http.DataReceiveProgressInfo) => {
        if (active.canceled || active.removed) {
          return;
        }
        const total = base + info2.totalSize;
        if (total > task.totalBytes) {
          task.totalBytes = total;
        }
      });

      const ended = this.waitForEnd(req, active);
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: this.headers(),
        connectTimeout: 15000,
        readTimeout: 120000,
        usingCache: false
      };
      if (base > 0) {
        options.resumeFrom = base;
      }
      const code = await req.requestInStream(info.url, options);
      if (code !== 200 && code !== 206) {
        throw new Error(`服务器返回 ${code}`);
      }
      await ended;

      if (active.canceled || active.removed) {
        return;
      }

      // 服务器忽略 Range 时会把整文件接在旧数据后面，检测到超量就丢掉重下
      if (task.totalBytes > 0 && written > task.totalBytes * 1.05) {
        Logger.w(`下载体积异常 ${written}/${task.totalBytes}，删除后重下`);
        try {
          fs.unlinkSync(task.filePath);
        } catch (e) {
          // 忽略
        }
        task.downloadedBytes = 0;
        task.status = DownloadStatus.WAITING;
        db.saveDownloadTask(task);
        return;
      }

      const size = this.fileSize(task.filePath);
      if (task.totalBytes > 0 && size < task.totalBytes * 0.95) {
        throw new Error('文件不完整');
      }
      task.downloadedBytes = size;
      task.totalBytes = size > 0 ? size : task.downloadedBytes;
      task.status = DownloadStatus.DONE;
      task.error = '';
      db.saveDownloadTask(task);
      Logger.i(`下载完成 ${task.title} ${formatBytes(size)}`);
      this.state.message = `已下载：${task.title}`;
      // 音频先落盘，歌词单独补；失败不影响下载状态
      this.saveLyrics(task);
    } catch (e) {
      if (active.removed) {
        return;
      }
      if (active.canceled) {
        task.status = DownloadStatus.PAUSED;
        db.saveDownloadTask(task);
        return;
      }
      task.status = DownloadStatus.FAILED;
      task.error = (e as Error).message;
      db.saveDownloadTask(task);
      Logger.w(`下载失败 ${task.title}: ${task.error}`);
    } finally {
      try {
        if (active.file !== null) {
          fs.closeSync(active.file);
        }
      } catch (e) {
        // 忽略
      }
      try {
        active.req?.destroy();
      } catch (e) {
        // 忽略
      }
      const rest: ActiveDownload[] = [];
      for (let i = 0; i < this.active.length; i++) {
        if (this.active[i] !== active) {
          rest.push(this.active[i]);
        }
      }
      this.active = rest;
      this.refreshCounters();
      this.pump();
    }
  }

  /** 等流结束；长时间没有新数据就判超时，避免 promise 永远挂着 */
  private waitForEnd(req: http.HttpRequest, active: ActiveDownload): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let settled = false;
      let timer: number = -1;
      const finish = (ok: boolean, msg: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer >= 0) {
          clearInterval(timer);
        }
        if (ok) {
          resolve();
        } else {
          reject(new Error(msg));
        }
      };
      req.on('dataEnd', () => {
        finish(true, '');
      });
      timer = setInterval(() => {
        if (active.canceled || active.removed) {
          finish(false, '已取消');
          return;
        }
        if (Date.now() - active.lastDataAt > IDLE_TIMEOUT_MS) {
          finish(false, '下载超时');
        }
      }, 1000);
    });
  }

  /**
   * 把在线歌词存到音频旁边，供离线播放时读取：
   *   <stem>.yrc / <stem>.lrc 原文，<stem>.trans 翻译
   * 已有歌词文件就跳过，不重复请求。
   */
  private async saveLyrics(task: DownloadTask): Promise<void> {
    if (task.remoteId <= 0 || task.filePath.length === 0) {
      return;
    }
    const base = this.stemOf(task.filePath);
    if (base.length === 0) {
      return;
    }
    if (fs.accessSync(`${base}.yrc`) || fs.accessSync(`${base}.lrc`) || fs.accessSync(`${base}.ttml`)) {
      return;
    }
    if (this.lyricTried.has(task.songPath)) {
      return;
    }
    this.lyricTried.add(task.songPath);
    try {
      const data: NeteaseLyric = await fetchLyric(task.remoteId);
      const hasYrc = data.yrc.length > 0;
      const main = hasYrc ? data.yrc : data.lrc;
      if (main.length > 0) {
        this.writeText(hasYrc ? `${base}.yrc` : `${base}.lrc`, main);
      }
      const trans = hasYrc
        ? (data.yrcTranslation.length > 0 ? data.yrcTranslation : data.translation)
        : data.translation;
      if (trans.length > 0) {
        this.writeText(`${base}.trans`, trans);
      }
      if (main.length > 0) {
        Logger.i(`歌词已保存 ${task.title}${trans.length > 0 ? '（含翻译）' : ''}`);
      } else {
        Logger.i(`这首歌没有歌词 ${task.title}`);
      }
    } catch (e) {
      Logger.w(`歌词保存失败 ${task.title}: ${(e as Error).message}`);
    }
  }

  private writeText(path: string, text: string): void {
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
  }

  private removeLyricFiles(task: DownloadTask): void {
    const base = this.stemOf(task.filePath);
    if (base.length === 0) {
      return;
    }
    const exts: string[] = ['.yrc', '.lrc', '.ttml', '.trans', '.tlyric'];
    for (let i = 0; i < exts.length; i++) {
      const p = `${base}${exts[i]}`;
      if (fs.accessSync(p)) {
        try {
          fs.unlinkSync(p);
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  /** audio.flac → audio；只去掉最后一段扩展名 */
  private stemOf(path: string): string {
    const slash = path.lastIndexOf('/');
    const dot = path.lastIndexOf('.');
    if (dot <= slash) {
      return path;
    }
    return path.substring(0, dot);
  }

  private headers(): Record<string, string> {
    const h: Record<string, string> = {};
    h['User-Agent'] = UA;
    h['Referer'] = 'https://music.163.com';
    h['Accept'] = '*/*';
    return h;
  }

  private refreshCounters(): void {
    let active = 0;
    let bytes = 0;
    const songs: Song[] = [];
    for (let i = 0; i < this.state.tasks.length; i++) {
      const t = this.state.tasks[i];
      if (t.status === DownloadStatus.DOWNLOADING) {
        active++;
      }
      if (t.status === DownloadStatus.DONE) {
        bytes += t.totalBytes;
        songs.push(this.songOf(t));
      }
    }
    this.state.activeCount = active;
    this.state.totalBytes = bytes;
    this.state.doneSongs = songs;
    this.state.version++;
  }

  /** 把已完成任务还原成本地 Song，播放与封面都用它 */
  songOf(task: DownloadTask): Song {
    const slash = task.filePath.lastIndexOf('/');
    const name = slash >= 0 ? task.filePath.substring(slash + 1) : task.filePath;
    const song = new Song(task.filePath, name);
    song.source = 'local';
    song.title = task.title;
    song.artist = task.artist;
    song.album = task.album;
    song.durationMs = task.durationMs;
    song.coverUrl = task.coverUrl;
    song.remoteId = task.remoteId;
    song.artistId = task.artistId;
    song.quality = task.quality;
    return song;
  }

  private activeOf(songPath: string): ActiveDownload | null {
    for (let i = 0; i < this.active.length; i++) {
      if (this.active[i].task.songPath === songPath) {
        return this.active[i];
      }
    }
    return null;
  }

  private fileSize(path: string): number {
    if (path.length === 0) {
      return 0;
    }
    try {
      return fs.statSync(path).size;
    } catch (e) {
      return 0;
    }
  }

  private safeName(title: string): string {
    let out = '';
    for (let i = 0; i < title.length; i++) {
      const c = title.charAt(i);
      if ('/\\:*?"<>|'.indexOf(c) >= 0) {
        out += '_';
      } else {
        out += c;
      }
    }
    if (out.length > 60) {
      out = out.substring(0, 60);
    }
    return out.length > 0 ? out : 'audio';
  }
}

/** 字节数转人读文案 */
export function formatBytes(bytes: number): string {
  if (bytes <= 0) {
    return '0 B';
  }
  if (bytes < 1024) {
    return `${Math.round(bytes)} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

export const downloader = new DownloadService();
