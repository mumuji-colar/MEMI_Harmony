import { media } from '@kit.MediaKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Song } from '../model/Song';
import { Logger } from '../common/Logger';
import { settings } from './SettingsService';
import { extensionOf, stemOf } from '../common/Format';

/** 能被 AVPlayer 直接吃的后缀。不同容器同一个后缀的情况很多，这里只做粗筛，真正能不能放由播放器决定。 */
const AUDIO_EXTENSIONS: string[] = [
  'mp3', 'flac', 'ape', 'wav', 'ogg', 'oga', 'm4a', 'aac', 'amr', 'opus',
  'wma', 'aiff', 'aif', 'alac', 'dsf', 'dff', 'mp4', 'mka'
];

const MAX_DEPTH: number = 8;

/** 专辑或艺术家的一个分组 */
export class GroupItem {
  name: string = '';
  count: number = 0;
  subtitle: string = '';
  /** 取组内第一首的路径来拿封面 */
  samplePath: string = '';
  /** 组内第一首的网络封面，在线曲目没有本地缩略图时用它 */
  coverUrl: string = '';
}

@ObservedV2
export class LibraryState {
  @Trace songs: Song[] = [];
  /** 经过搜索和排序后真正显示的列表 */
  @Trace displaySongs: Song[] = [];
  @Trace scanning: boolean = false;
  /** 形如 "12/80" */
  @Trace progressText: string = '';
  @Trace rootPath: string = '';
  @Trace message: string = '';
  /** 搜索关键词 */
  @Trace query: string = '';
  /** 排序方式，见 SortMode */
  @Trace sortMode: number = 0;
  @Trace albumGroups: GroupItem[] = [];
  @Trace artistGroups: GroupItem[] = [];
}

/** 排序方式 */
export enum SortMode {
  TITLE = 0,
  ARTIST = 1,
  DURATION = 2
}

/**
 * 本地曲库扫描。
 *
 * 鸿蒙 NEXT 没有 MediaStore 那种全局音乐库（photoAccessHelper 只管图片视频，
 * 老的 mediaLibrary 已移除），所以只能拿用户授权过的目录自己扫盘。
 */
export class LibraryService {
  readonly state: LibraryState = new LibraryState();

  /**
   * 被收藏或加进歌单的在线曲目。
   * 它们不进 state.songs（否则会混进本地曲库列表），
   * 但要能被 findByPath 找到，收藏页和歌单页才不会丢歌。
   */
  private remote: Map<string, Song> = new Map();

  /** 装载在线曲目索引（启动时调一次） */
  setRemoteSongs(songs: Song[]): void {
    this.remote.clear();
    for (let i = 0; i < songs.length; i++) {
      this.remote.set(songs[i].path, songs[i]);
    }
    Logger.i(`在线曲目索引 ${songs.length} 首`);
  }

  /** 收藏/加歌单时立刻让索引生效，不必等重启 */
  rememberRemote(song: Song): void {
    if (song.isRemote()) {
      this.remote.set(song.path, song);
    }
  }

  /** 按 path 找歌：本地曲库优先，其次是在线索引 */
  findByPath(path: string): Song | null {
    for (let i = 0; i < this.state.songs.length; i++) {
      if (this.state.songs[i].path === path) {
        return this.state.songs[i];
      }
    }
    const hit = this.remote.get(path);
    return hit === undefined ? null : hit;
  }

  /** 把一串 path 还原成 Song，找不到的跳过 */
  resolvePaths(paths: string[]): Song[] {
    const out: Song[] = [];
    for (let i = 0; i < paths.length; i++) {
      const s = this.findByPath(paths[i]);
      if (s !== null) {
        out.push(s);
      }
    }
    return out;
  }

  async scan(root: string): Promise<void> {
    if (this.state.scanning) {
      return;
    }
    if (root.length === 0) {
      this.state.message = '还没选目录';
      return;
    }
    this.state.scanning = true;
    this.state.message = '';
    this.state.progressText = '遍历目录…';
    this.state.songs = [];
    this.state.rootPath = root;

    try {
      const paths: string[] = [];
      this.collect(root, paths, 0);
      Logger.i(`扫描 ${root} → 命中 ${paths.length} 个音频`);

      if (paths.length === 0) {
        this.state.message = '这个目录里没有可识别的音频文件';
        return;
      }

      const songs: Song[] = [];
      for (let i = 0; i < paths.length; i++) {
        this.state.progressText = `读取标签 ${i + 1}/${paths.length}`;
        const song = await this.readMeta(paths[i]);
        songs.push(song);
      }
      songs.sort((a: Song, b: Song) => {
        const at = a.title.toLowerCase();
        const bt = b.title.toLowerCase();
        if (at < bt) {
          return -1;
        }
        return at > bt ? 1 : 0;
      });

      this.applySongs(songs);
      this.state.message = `共 ${songs.length} 首`;
    } catch (e) {
      const err = e as BusinessError;
      this.state.message = `扫描失败 ${err.code}: ${err.message}`;
      Logger.e(this.state.message);
    } finally {
      this.state.scanning = false;
      this.state.progressText = '';
    }
  }

  clear(): void {
    this.state.songs = [];
    this.state.displaySongs = [];
    this.state.rootPath = '';
    this.state.message = '';
  }

  /** 从曲库移除一首（只改列表，不删文件） */
  removeSong(path: string): void {
    const kept: Song[] = this.state.songs.filter((s: Song) => s.path !== path);
    if (kept.length === this.state.songs.length) {
      return;
    }
    this.applySongs(kept);
    this.state.message = `已移除，剩 ${kept.length} 首`;
    Logger.i(`移除歌曲 ${path}`);
  }

  setQuery(q: string): void {
    this.state.query = q;
    this.recompute();
  }

  setSort(mode: number): void {
    this.state.sortMode = mode;
    this.recompute();
  }

  /** 标题 → 艺术家 → 时长 轮流切 */
  cycleSort(): number {
    let next = SortMode.TITLE;
    if (this.state.sortMode === SortMode.TITLE) {
      next = SortMode.ARTIST;
    } else if (this.state.sortMode === SortMode.ARTIST) {
      next = SortMode.DURATION;
    }
    this.setSort(next);
    return next;
  }

  sortLabel(): string {
    if (this.state.sortMode === SortMode.ARTIST) {
      return '艺术家';
    }
    if (this.state.sortMode === SortMode.DURATION) {
      return '时长';
    }
    return '标题';
  }

  private applySongs(songs: Song[]): void {
    this.state.songs = this.dedupe(songs);
    this.recompute();
  }

  /**
   * 按「文件名 + 字节数」去重。
   * 同一条音频可能以不同路径进来（示例曲库复制的、选择器给 file:// 的），
   * 光按 path 去重会留下两份一模一样的条目。
   */
  private dedupe(songs: Song[]): Song[] {
    const seen: Set<string> = new Set();
    const out: Song[] = [];
    for (let i = 0; i < songs.length; i++) {
      const s = songs[i];
      const key = `${s.fileName.toLowerCase()}|${s.sizeBytes}`;
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      out.push(s);
    }
    return out;
  }

  /** 按搜索词过滤 + 当前排序方式重排，结果写进 displaySongs */
  private recompute(): void {
    const q = this.state.query.trim().toLowerCase();
    let list: Song[] = this.state.songs;
    if (q.length > 0) {
      list = list.filter((s: Song) => this.matches(s, q));
    }
    const sorted: Song[] = list.slice();
    const mode = this.state.sortMode;
    sorted.sort((a: Song, b: Song) => this.compare(a, b, mode));
    this.state.displaySongs = sorted;

    this.state.albumGroups = this.buildGroups(sorted, true);
    this.state.artistGroups = this.buildGroups(sorted, false);
  }

  /** 按专辑或艺术家聚合成组，按名字排序 */
  private buildGroups(songs: Song[], byAlbum: boolean): GroupItem[] {
    const map: Map<string, GroupItem> = new Map();
    for (let i = 0; i < songs.length; i++) {
      const song = songs[i];
      let key = byAlbum ? song.album : song.artist;
      if (key.length === 0) {
        key = byAlbum ? '未知专辑' : '未知艺术家';
      }
      const existing = map.get(key);
      if (existing === undefined) {
        const item = new GroupItem();
        item.name = key;
        item.count = 1;
        item.samplePath = song.path;
        item.coverUrl = song.coverUrl;
        // 艺术家组的副标题要等数量统计完再填，这里先留空
        item.subtitle = byAlbum
          ? (song.artist.length > 0 ? song.artist : '未知艺术家')
          : '';
        map.set(key, item);
      } else {
        existing.count++;
      }
    }

    const groups: GroupItem[] = [];
    map.forEach((value: GroupItem) => {
      groups.push(value);
    });
    groups.sort((a: GroupItem, b: GroupItem) => {
      const an = a.name.toLowerCase();
      const bn = b.name.toLowerCase();
      if (an === bn) {
        return 0;
      }
      return an < bn ? -1 : 1;
    });
    // 副标题由调用方按需显示，这里不再重复写数量
    if (!byAlbum) {
      for (let i = 0; i < groups.length; i++) {
        groups[i].subtitle = '';
      }
    }
    return groups;
  }

  /** 某张专辑 / 某个艺术家下的歌（已应用搜索和排序） */
  songsOfGroup(byAlbum: boolean, key: string): Song[] {
    return this.state.displaySongs.filter((s: Song) => {
      const v = byAlbum ? s.album : s.artist;
      const name = v.length === 0 ? (byAlbum ? '未知专辑' : '未知艺术家') : v;
      return name === key;
    });
  }

  private matches(song: Song, q: string): boolean {
    return song.title.toLowerCase().indexOf(q) >= 0
      || song.artist.toLowerCase().indexOf(q) >= 0
      || song.album.toLowerCase().indexOf(q) >= 0;
  }

  private compare(a: Song, b: Song, mode: number): number {
    if (mode === SortMode.ARTIST) {
      const aa = a.artist.length > 0 ? a.artist.toLowerCase() : 'zzzz';
      const bb = b.artist.length > 0 ? b.artist.toLowerCase() : 'zzzz';
      if (aa !== bb) {
        return aa < bb ? -1 : 1;
      }
    } else if (mode === SortMode.DURATION) {
      if (a.durationMs !== b.durationMs) {
        return a.durationMs - b.durationMs;
      }
    }
    const at = a.title.toLowerCase();
    const bt = b.title.toLowerCase();
    if (at === bt) {
      return 0;
    }
    return at < bt ? -1 : 1;
  }

  /** 启动时把上次保存的曲库灌回来。数量已经写在媒体库副标题里，这里不再提示 */
  restore(songs: Song[]): void {
    this.applySongs(songs);
  }

  /**
   * 把一批歌并进现有曲库（按 path 去重）。
   * 「示例曲库」用完会调这个，避免把用户导入的歌冲掉。
   */
  mergeSongs(incoming: Song[]): void {
    if (incoming.length === 0) {
      return;
    }
    const merged: Song[] = this.state.songs.slice();
    const known: string[] = [];
    for (let i = 0; i < merged.length; i++) {
      known.push(merged[i].path);
    }
    const knownName: string[] = [];
    for (let i = 0; i < merged.length; i++) {
      knownName.push(`${merged[i].fileName.toLowerCase()}|${merged[i].sizeBytes}`);
    }
    let added = 0;
    for (let i = 0; i < incoming.length; i++) {
      if (known.indexOf(incoming[i].path) < 0
        && knownName.indexOf(`${incoming[i].fileName.toLowerCase()}|${incoming[i].sizeBytes}`) < 0) {
        merged.push(incoming[i]);
        known.push(incoming[i].path);
        knownName.push(`${incoming[i].fileName.toLowerCase()}|${incoming[i].sizeBytes}`);
        added++;
      }
    }
    if (added > 0) {
      merged.sort((a: Song, b: Song) => {
        const at = a.title.toLowerCase();
        const bt = b.title.toLowerCase();
        if (at < bt) {
          return -1;
        }
        return at > bt ? 1 : 0;
      });
      this.applySongs(merged);
    }
  }

  /**
   * 直接导入用户选中的若干文件（选择器给的是 file:// 或 /storage 下的 URI）。
   * 按 path 去重，重复选中不会加两遍。
   */
  async addFiles(uris: string[]): Promise<void> {
    if (uris.length === 0) {
      return;
    }
    this.state.scanning = true;
    this.state.message = '';
    try {
      const songs: Song[] = this.state.songs.slice();
      const known: string[] = [];
      for (let i = 0; i < songs.length; i++) {
        known.push(songs[i].path);
      }

      let added = 0;
      let skipped = 0;
      for (let i = 0; i < uris.length; i++) {
        const uri = uris[i];
        if (known.indexOf(uri) >= 0) {
          continue;
        }
        this.state.progressText = `导入 ${i + 1}/${uris.length}`;
        const song = await this.readMeta(uri);
        // 可选过滤：提示音、铃声这类短音频不进曲库
        if (settings.state.skipShort && song.durationMs > 0 && song.durationMs < 30000) {
          skipped++;
          continue;
        }
        songs.push(song);
        known.push(uri);
        added++;
      }

      this.applySongs(songs);
      this.state.message = added > 0
        ? (skipped > 0 ? `导入 ${added} 首，跳过 ${skipped} 个短音频` : `导入 ${added} 首`)
        : (skipped > 0 ? `已跳过 ${skipped} 个短音频` : '选中的文件都已在曲库里');
    } catch (e) {
      const err = e as BusinessError;
      this.state.message = `导入失败 ${err.code}: ${err.message}`;
      Logger.e(this.state.message);
    } finally {
      this.state.scanning = false;
      this.state.progressText = '';
    }
  }

  /** 递归收集音频文件路径，深度上限兜底防止符号链接成环 */
  private collect(dir: string, out: string[], depth: number): void {
    if (depth > MAX_DEPTH) {
      return;
    }
    let entries: string[] = [];
    try {
      entries = fs.listFileSync(dir);
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`列目录失败 ${dir} ${err.code}`);
      return;
    }
    for (let i = 0; i < entries.length; i++) {
      const name = entries[i];
      if (name.startsWith('.')) {
        continue;
      }
      const full = `${dir}/${name}`;
      let isDir = false;
      try {
        isDir = fs.statSync(full).isDirectory();
      } catch (e) {
        continue;
      }
      if (isDir) {
        this.collect(full, out, depth + 1);
      } else if (AUDIO_EXTENSIONS.indexOf(extensionOf(name)) >= 0) {
        out.push(full);
      }
    }
  }

  /**
   * 读一首歌的标签。
   * 读不到标签不算失败——文件名回落成标题，照样能播。
   */
  private async readMeta(path: string): Promise<Song> {
    const slash = path.lastIndexOf('/');
    const rawFileName = slash >= 0 ? path.substring(slash + 1) : path;
    const fileName = this.prettyName(rawFileName);
    const song = new Song(path, fileName);
    song.title = stemOf(fileName);

    let fd: number = -1;
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      fd = file.fd;
      const stat = fs.statSync(fd);
      song.sizeBytes = stat.size;

      const extractor = await media.createAVMetadataExtractor();
      try {
        extractor.fdSrc = { fd: fd, offset: 0, length: stat.size };
        const meta = await extractor.fetchMetadata();
        const title = this.cleanTag(meta.title);
        const artist = this.cleanTag(meta.artist);
        const album = this.cleanTag(meta.album);
        if (title.length > 0) {
          song.title = this.prettyName(title);
        }
        if (artist.length > 0) {
          song.artist = this.prettyName(artist);
        }
        if (album.length > 0) {
          song.album = this.prettyName(album);
        }
        if (meta.mimeType !== undefined) {
          song.mimeType = meta.mimeType;
        }
        if (meta.duration !== undefined) {
          const d = Number(meta.duration);
          if (!Number.isNaN(d)) {
            song.durationMs = d;
          }
        }
      } finally {
        await extractor.release();
      }
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`读标签失败 ${fileName} ${err.code}: ${err.message}`);
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (e) {
          Logger.w('关闭 fd 失败');
        }
      }
    }
    return song;
  }

  /**
   * 去掉标签里的 BOM 和零宽字符。
   * ID3v2.3 存非 ASCII 用 UTF-16，解出来首尾常带 \uFEFF，不清掉会污染排序和显示。
   */
  private cleanTag(raw: string | undefined): string {
    if (raw === undefined) {
      return '';
    }
    let out = raw;
    while (out.length > 0) {
      const c = out.charCodeAt(0);
      if (c === 0xFEFF || c === 0x200B || c === 0x200C || c === 0x200D
        || c === 0x200E || c === 0x200F) {
        out = out.substring(1);
      } else {
        break;
      }
    }
    return out.trim();
  }

  /** 文件名/标签可能是百分号编码的，能解就解 */
  private prettyName(raw: string): string {
    if (raw.indexOf('%') < 0) {
      return raw;
    }
    try {
      return decodeURIComponent(raw);
    } catch (e) {
      return raw;
    }
  }
}

export const library: LibraryService = new LibraryService();
