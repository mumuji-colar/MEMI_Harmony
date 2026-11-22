import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';
import { cover } from './CoverService';

/** 各项占用的快照。字段都是字节数 */
@ObservedV2
export class StorageState {
  @Trace downloads: number = 0;
  @Trace lyrics: number = 0;
  @Trace database: number = 0;
  @Trace cache: number = 0;
  @Trace scanning: boolean = false;
  @Trace ready: boolean = false;
  @Trace message: string = '';

  total(): number {
    return this.downloads + this.lyrics + this.database + this.cache;
  }
}

/**
 * 存储占用统计与缓存清理。
 *
 * 只碰应用沙箱里的四个目录：
 * - filesDir/downloads  离线歌曲与歌词
 * - filesDir/lyrics     手动导入的歌词
 * - databaseDir         曲库、歌单、收藏、播放历史
 * - cacheDir            系统缓存（封面解码中间文件等），可以放心删
 *
 * 用户通过选择器导入的音频不在沙箱里，这里既不统计也不删除。
 */
export class StorageService {
  readonly state: StorageState = new StorageState();

  /** 重新统计四个目录的体积 */
  async measure(ctx: common.UIAbilityContext): Promise<void> {
    this.state.scanning = true;
    try {
      this.state.downloads = await this.sizeOf(`${ctx.filesDir}/downloads`);
      this.state.lyrics = await this.sizeOf(`${ctx.filesDir}/lyrics`);
      this.state.database = await this.sizeOf(ctx.databaseDir);
      this.state.cache = await this.sizeOf(ctx.cacheDir);
      this.state.ready = true;
      this.state.message = '';
      Logger.i(`存储统计 下载=${this.state.downloads} 歌词=${this.state.lyrics} `
        + `数据库=${this.state.database} 缓存=${this.state.cache}`);
    } catch (e) {
      const err = e as BusinessError;
      this.state.message = `统计失败 ${err.code}`;
      Logger.w(`存储统计失败 ${err.code}: ${err.message}`);
    } finally {
      this.state.scanning = false;
    }
  }

  /**
   * 清理缓存目录。
   * 返回清掉的字节数（清理前统计），失败时返回 -1。
   */
  async clearCache(ctx: common.UIAbilityContext): Promise<number> {
    const before = await this.sizeOf(ctx.cacheDir);
    try {
      await this.clearDir(ctx.cacheDir, 0);
      // 内存里解好的封面也一起释放，不然清了盘还占着内存
      cover.clear();
      this.state.cache = 0;
      Logger.i(`缓存已清理 ${before} 字节`);
      return before;
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`清理缓存失败 ${err.code}: ${err.message}`);
      this.state.message = `清理失败 ${err.code}`;
      return -1;
    }
  }

  /** 目录体积；不存在或读不到都按 0 算，不要因为一个坏目录整页报错 */
  private async sizeOf(path: string): Promise<number> {
    try {
      if (path.length === 0 || !fs.accessSync(path)) {
        return 0;
      }
      const st = await fs.stat(path);
      if (!st.isDirectory()) {
        return st.size;
      }
      return await this.walk(path, 0);
    } catch (e) {
      return 0;
    }
  }

  private async walk(dir: string, depth: number): Promise<number> {
    if (depth > 6) {
      return 0;
    }
    let total = 0;
    const names = await fs.listFile(dir);
    for (let i = 0; i < names.length; i++) {
      const p = `${dir}/${names[i]}`;
      try {
        const st = await fs.stat(p);
        if (st.isDirectory()) {
          total += await this.walk(p, depth + 1);
        } else {
          total += st.size;
        }
      } catch (e) {
        // 单个文件被删/无权限，跳过即可
      }
    }
    return total;
  }

  /** 逐层删除目录内容，保留目录本身 */
  private async clearDir(dir: string, depth: number): Promise<void> {
    if (depth > 6 || !fs.accessSync(dir)) {
      return;
    }
    const names = await fs.listFile(dir);
    for (let i = 0; i < names.length; i++) {
      const p = `${dir}/${names[i]}`;
      try {
        const st = await fs.stat(p);
        if (st.isDirectory()) {
          // rmdir 在鸿蒙上是递归删除
          await fs.rmdir(p);
        } else {
          await fs.unlink(p);
        }
      } catch (e) {
        // 正在被使用的文件删不掉，跳过
      }
    }
  }
}

export const storage: StorageService = new StorageService();
