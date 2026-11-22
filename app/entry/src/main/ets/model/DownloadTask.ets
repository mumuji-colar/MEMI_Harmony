/** 下载任务状态 */
export enum DownloadStatus {
  WAITING = 0,
  DOWNLOADING = 1,
  PAUSED = 2,
  DONE = 3,
  FAILED = 4
}

/**
 * 一个下载任务。
 *
 * 用在线曲目的稳定标识（netease://id）做主键，重复下载会被合并；
 * filePath 是沙箱里的真实文件，下载完成后用它构造本地 Song。
 */
@ObservedV2
export class DownloadTask {
  /** 在线曲目标识，netease://<id> */
  songPath: string = '';
  remoteId: number = 0;
  title: string = '';
  artist: string = '';
  album: string = '';
  artistId: number = 0;
  durationMs: number = 0;
  coverUrl: string = '';
  /** 下载时使用的音质文案，如「无损」「高 320k」 */
  quality: string = '';
  /** 请求码率档位（standard/exhigh/lossless/hires），续传时按同一档解析 */
  level: string = '';

  @Trace filePath: string = '';
  @Trace totalBytes: number = 0;
  @Trace downloadedBytes: number = 0;
  @Trace status: number = DownloadStatus.WAITING;
  /** 失败原因，成功后清空 */
  @Trace error: string = '';
  createdAt: number = 0;

  progress(): number {
    if (this.totalBytes <= 0) {
      return 0;
    }
    const p = this.downloadedBytes / this.totalBytes;
    return p > 1 ? 1 : p;
  }

  isDone(): boolean {
    return this.status === DownloadStatus.DONE;
  }

  statusLabel(): string {
    if (this.status === DownloadStatus.DONE) {
      return '已完成';
    }
    if (this.status === DownloadStatus.DOWNLOADING) {
      return '下载中';
    }
    if (this.status === DownloadStatus.PAUSED) {
      return '已暂停';
    }
    if (this.status === DownloadStatus.FAILED) {
      return this.error.length > 0 ? this.error : '失败';
    }
    return '等待中';
  }
}
