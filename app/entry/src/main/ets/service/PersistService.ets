import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileShare } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Song } from '../model/Song';
import { db } from './Db';
import { Logger } from '../common/Logger';
import { settings } from './SettingsService';

/** 上次播放位置的快照 */
export interface PlaybackSnapshot {
  path: string;
  positionMs: number;
  mode: number;
}

const STORE_NAME: string = 'memi_store';
const KEY_LIBRARY: string = 'library_json';
const KEY_LAST_PATH: string = 'last_path';
const KEY_LAST_POS: string = 'last_position';
const KEY_LAST_MODE: string = 'last_mode';
const KEY_LAST_REMOTE: string = 'last_remote_song';

/** 落盘用的扁平结构，避免依赖 Song 类的原型 */
interface SongRecord {
  path: string;
  fileName: string;
  title: string;
  artist: string;
  album: string;
  durationMs: number;
  sizeBytes: number;
  mimeType: string;
}

/** 上次播放的在线曲目快照，重启后用来复原播放条与队列 */
interface RemoteSongRecord {
  path: string;
  title: string;
  artist: string;
  album: string;
  durationMs: number;
  remoteId: number;
  coverUrl: string;
  artistId?: number;
}

/**
 * 曲库持久化 + 文件授权持久化。
 *
 * 两件事必须配对：光把路径存下来没用，重启后系统会收回选择器给的临时授权，
 * 必须 fileShare.persistPermission 把 URI 变成长期可读，否则列表能显示但一播就失败。
 */
export class PersistService {
  private store: preferences.Preferences | null = null;

  private async ensureStore(ctx: common.UIAbilityContext): Promise<preferences.Preferences | null> {
    if (this.store !== null) {
      return this.store;
    }
    try {
      this.store = await preferences.getPreferences(ctx, STORE_NAME);
      return this.store;
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`打开 preferences 失败 ${err.code}: ${err.message}`);
      return null;
    }
  }

  /** 曲库整体落盘（RDB 事务） */
  async saveLibrary(ctx: common.UIAbilityContext, songs: Song[]): Promise<void> {
    await db.replaceLibrary(songs);
  }

  /** 曲库读取（RDB） */
  async loadLibrary(ctx: common.UIAbilityContext): Promise<Song[]> {
    const songs = await db.loadSongs();
    Logger.i(`曲库已从 RDB 读取 ${songs.length} 首`);
    return songs;
  }

  /** 记住「上次播到哪首、第几秒、什么模式」 */
  async savePlayback(ctx: common.UIAbilityContext, path: string, positionMs: number,
    mode: number, current: Song | null = null): Promise<void> {
    if (path.length === 0) {
      return;
    }
    // 用户关掉「记住播放进度」就不要再写，免得关掉后还残留旧快照
    if (!settings.state.rememberProgress) {
      return;
    }
    const s = await this.ensureStore(ctx);
    if (s === null) {
      return;
    }
    try {
      await s.put(KEY_LAST_PATH, path);
      await s.put(KEY_LAST_POS, Math.floor(positionMs));
      await s.put(KEY_LAST_MODE, mode);
      // 在线曲目不在本地曲库里，得单独留一份元数据，否则重启后无法复原
      if (current !== null && current.isRemote()) {
        const rec: RemoteSongRecord = {
          path: current.path,
          title: current.title,
          artist: current.artist,
          album: current.album,
          durationMs: current.durationMs,
          remoteId: current.remoteId,
          coverUrl: current.coverUrl,
          artistId: current.artistId
        };
        await s.put(KEY_LAST_REMOTE, JSON.stringify(rec));
      } else {
        await s.delete(KEY_LAST_REMOTE);
      }
      await s.flush();
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`保存播放位置失败 ${err.code}`);
    }
  }

  /** 读回上次播的在线曲目，没有就返回 null */
  async loadLastRemoteSong(ctx: common.UIAbilityContext): Promise<Song | null> {
    const s = await this.ensureStore(ctx);
    if (s === null) {
      return null;
    }
    try {
      const raw = (await s.get(KEY_LAST_REMOTE, '')) as string;
      if (raw.length === 0) {
        return null;
      }
      const rec = JSON.parse(raw) as RemoteSongRecord;
      if (rec.remoteId <= 0) {
        return null;
      }
      const song = new Song(rec.path, '');
      song.source = 'netease';
      song.remoteId = rec.remoteId;
      song.title = rec.title;
      song.artist = rec.artist;
      song.album = rec.album;
      song.durationMs = rec.durationMs;
      song.coverUrl = rec.coverUrl;
      song.artistId = rec.artistId === undefined ? 0 : rec.artistId;
      return song;
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`读取在线曲目快照失败 ${err.code}`);
      return null;
    }
  }

  async loadPlayback(ctx: common.UIAbilityContext): Promise<PlaybackSnapshot | null> {
    const s = await this.ensureStore(ctx);
    if (s === null) {
      return null;
    }
    try {
      const path = (await s.get(KEY_LAST_PATH, '')) as string;
      if (path.length === 0) {
        return null;
      }
      const pos = (await s.get(KEY_LAST_POS, 0)) as number;
      const mode = (await s.get(KEY_LAST_MODE, 0)) as number;
      return { path: path, positionMs: pos, mode: mode };
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`读取播放位置失败 ${err.code}`);
      return null;
    }
  }

  /** 把选择器给的临时授权转成长期授权 */
  async persistUris(uris: string[]): Promise<void> {    if (uris.length === 0) {
      return;
    }
    const policies: fileShare.PolicyInfo[] = [];
    for (let i = 0; i < uris.length; i++) {
      policies.push({
        uri: uris[i],
        operationMode: fileShare.OperationMode.READ_MODE
      });
    }
    try {
      await fileShare.persistPermission(policies);
      Logger.i(`已持久化 ${policies.length} 个 URI 授权`);
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`持久化授权失败 ${err.code}: ${err.message}`);
    }
  }
}

export const persist: PersistService = new PersistService();
