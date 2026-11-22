import { media } from '@kit.MediaKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';

const CACHE_LIMIT: number = 16;
const THUMB_LIMIT: number = 80;
const THUMB_SIZE: number = 96;

@ObservedV2
export class ThumbState {
  /** 每解码出一张缩略图就 +1，UI 靠它触发刷新 */
  @Trace version: number = 0;
}

@ObservedV2
export class CoverState {
  /** 当前封面归属的曲目路径 */
  @Trace path: string = '';
  /** 解码出来的封面，null 表示这首没有封面 */
  @Trace cover: image.PixelMap | null = null;
  /** 正在解码的曲目路径，空串表示空闲 */
  @Trace loadingPath: string = '';
  /** 从封面算出的深色背景（不透明），播放页用它做底色 */
  @Trace backdrop: string = '';
  /** 封面主色（原色），给光晕和阴影用 */
  @Trace dominant: string = '';
}

/**
 * 专辑封面：从音频内嵌标签里抽图（AVMetadataExtractor.fetchAlbumCover）。
 *
 * 缓存策略是简单的 LRU：Map 的插入顺序就是访问顺序，命中时删了重插，
 * 超过上限就删最早那个。PixelMap 是原生内存，不回收会一直占着。
 */
export class CoverService {
  readonly state: CoverState = new CoverState();
  readonly thumbState: ThumbState = new ThumbState();
  private cache: Map<string, image.PixelMap> = new Map();
  private thumbs: Map<string, image.PixelMap> = new Map();
  private thumbMissed: Set<string> = new Set();

  /** 列表用的小图，没解出来返回 null */
  thumbOf(path: string): image.PixelMap | null {
    const t = this.thumbs.get(path);
    return t === undefined ? null : t;
  }

  /**
   * 解码一张列表缩略图。
   * 单独解一次再缩小，而不是拿播放页那张大图去缩——那样会把大图也缩坏。
   */
  async loadThumb(path: string): Promise<void> {
    if (path.length === 0 || this.thumbs.has(path) || this.thumbMissed.has(path)) {
      return;
    }
    let fd: number = -1;
    let extractor: media.AVMetadataExtractor | null = null;
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      fd = file.fd;
      const size = fs.statSync(fd).size;
      extractor = await media.createAVMetadataExtractor();
      extractor.fdSrc = { fd: fd, offset: 0, length: size };
      const coverPm = await extractor.fetchAlbumCover();

      const info = coverPm.getImageInfoSync();
      const maxSide = Math.max(info.size.width, info.size.height);
      if (maxSide > THUMB_SIZE) {
        const ratio = THUMB_SIZE / maxSide;
        coverPm.scaleSync(ratio, ratio);
      }
      this.thumbs.set(path, coverPm);
      while (this.thumbs.size > THUMB_LIMIT) {
        const oldest = this.thumbs.keys().next();
        if (oldest.done === true) {
          break;
        }
        this.thumbs.delete(oldest.value as string);
      }
      this.thumbState.version++;
    } catch (e) {
      // 没封面的歌很常见，记下来别反复重试
      this.thumbMissed.add(path);
    } finally {
      if (extractor !== null) {
        extractor.release().catch((e: BusinessError) => {
          Logger.w(`release thumb extractor ${e.code}`);
        });
      }
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (e) {
          Logger.w('关闭缩略图 fd 失败');
        }
      }
    }
  }


  /** 换歌时调用；同一首不会重复解码 */
  async load(path: string): Promise<void> {
    if (path.length === 0) {
      this.state.path = '';
      this.state.cover = null;
      this.state.backdrop = '';
      this.state.dominant = '';
      return;
    }
    if (this.state.path === path) {
      return;
    }
    this.state.path = path;

    const cached = this.cache.get(path);
    if (cached !== undefined) {
      this.cache.delete(path);
      this.cache.set(path, cached);
      this.state.cover = cached;
      this.applyColors(cached);
      return;
    }

    this.state.cover = null;
    this.state.backdrop = '';
    this.state.dominant = '';
    this.state.loadingPath = path;

    let fd: number = -1;
    let extractor: media.AVMetadataExtractor | null = null;
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      fd = file.fd;
      const size = fs.statSync(fd).size;

      extractor = await media.createAVMetadataExtractor();
      extractor.fdSrc = { fd: fd, offset: 0, length: size };
      const cover = await extractor.fetchAlbumCover();

      // 中途可能又切歌了，过期的结果直接丢掉
      if (this.state.path !== path) {
        return;
      }
      this.putCache(path, cover);
      this.state.cover = cover;
      this.applyColors(cover);
      Logger.i(`封面已加载 ${path.substring(path.lastIndexOf('/') + 1)} 主色=${this.state.dominant}`);
    } catch (e) {
      const err = e as BusinessError;
      // 没有封面很常见，不是错误，用 warn 级别记一下就行
      Logger.w(`无封面 ${err.code}: ${err.message}`);
    } finally {
      if (extractor !== null) {
        extractor.release().catch((e: BusinessError) => {
          Logger.w(`release extractor ${e.code}`);
        });
      }
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (e) {
          Logger.w('关闭封面 fd 失败');
        }
      }
      this.state.loadingPath = '';
    }
  }

  clear(): void {
    this.cache.clear();
    this.state.path = '';
    this.state.cover = null;
  }

  /**
   * 取封面主色。
   *
   * 直接读原图的像素再抽样求平均——**不能缩图**：
   * cloneSync + scaleSync 会动到底层像素缓冲，播放页那张封面会被一起缩成几像素的糊图。
   * 扫描时按步长抽样（约 1000 个点），大图也不会读取太多像素。
   */
  private applyColors(pm: image.PixelMap): void {
    try {
      const info = pm.getImageInfoSync();
      const w = info.size.width;
      const h = info.size.height;
      if (w <= 0 || h <= 0) {
        return;
      }
      // 超大图跳过取色，避免一次性读几十兆；退回主题色即可
      const totalPixels = w * h;
      if (totalPixels > 4000000) {
        Logger.w(`封面 ${w}x${h} 过大，跳过取色`);
        return;
      }
      const bytes = pm.getPixelBytesNumber();
      if (bytes <= 0) {
        return;
      }
      const buf = new ArrayBuffer(bytes);
      pm.readPixelsToBufferSync(buf);
      const px = new Uint8Array(buf);

      // 每像素 4 字节；目标采样约 1000 个点
      const stepPixels = Math.max(1, Math.floor(totalPixels / 1000));
      let r = 0;
      let g = 0;
      let b = 0;
      let n = 0;
      for (let p = 0; p < totalPixels; p += stepPixels) {
        const i = p * 4;
        if (i + 2 >= px.length) {
          break;
        }
        if (i + 3 < px.length && px[i + 3] < 16) {
          continue;
        }
        r += px[i];
        g += px[i + 1];
        b += px[i + 2];
        n++;
      }
      if (n === 0) {
        return;
      }
      r = Math.round(r / n);
      g = Math.round(g / n);
      b = Math.round(b / n);

      this.state.dominant = this.hex3(r, g, b);
      // 背景要压暗：主色只占两成，剩下用深棕打底，保证文字对比度
      this.state.backdrop = this.hex3(
        Math.round(r * 0.22 + 22),
        Math.round(g * 0.22 + 18),
        Math.round(b * 0.22 + 16));
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`取封面主色失败 ${err.code}`);
    }
  }

  private byte2hex(v: number): string {
    const c = v < 0 ? 0 : (v > 255 ? 255 : v);
    const h = c.toString(16);
    return h.length < 2 ? `0${h}` : h;
  }

  private hex3(r: number, g: number, b: number): string {
    return `#${this.byte2hex(r)}${this.byte2hex(g)}${this.byte2hex(b)}`;
  }

  private putCache(path: string, cover: image.PixelMap): void {
    this.cache.set(path, cover);
    while (this.cache.size > CACHE_LIMIT) {
      const oldest = this.cache.keys().next();
      if (oldest.done === true) {
        break;
      }
      this.cache.delete(oldest.value as string);
    }
  }
}

export const cover: CoverService = new CoverService();
