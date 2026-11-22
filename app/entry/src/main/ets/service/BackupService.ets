import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';
import { db } from './Db';
import { settings } from './SettingsService';
import { Playlist } from '../model/Playlist';

const APP_TAG: string = 'MEMI-Harmony';
const SCHEMA: number = 1;

interface BackupPlaylist {
  id: string;
  name: string;
  createdAt: number;
  paths: string[];
}

/** 备份文件结构。字段只增不改，旧版本缺字段时按空处理 */
interface BackupFile {
  app: string;
  schema: number;
  exportedAt: number;
  settings: string;
  playlists: BackupPlaylist[];
  favorites: string[];
}

/** 恢复结果，给界面拼提示用 */
export interface RestoreResult {
  ok: boolean;
  message: string;
  playlists: number;
  favorites: number;
}

/**
 * 设置 / 歌单 / 收藏的备份与恢复。
 *
 * 只导数据不导音频：音频在沙箱 downloads 里可能有几个 G，
 * 而且换机以后路径全变，导过去也没法播。所以备份里存的是**路径列表**，
 * 恢复后指向同一个位置；换设备后需要在曲库里重新导入一次，歌单会按路径自动接上。
 */
export class BackupService {
  async exportTo(uri: string): Promise<string> {
    const lists = await db.loadPlaylists();
    const favorites = await db.favoritePaths();

    const out: BackupPlaylist[] = [];
    for (let i = 0; i < lists.length; i++) {
      out.push({
        id: lists[i].id,
        name: lists[i].name,
        createdAt: lists[i].createdAt,
        paths: lists[i].paths.slice()
      });
    }

    const file: BackupFile = {
      app: APP_TAG,
      schema: SCHEMA,
      exportedAt: Date.now(),
      settings: settings.exportJson(),
      playlists: out,
      favorites: favorites.slice()
    };
    const json = JSON.stringify(file);

    const f = fs.openSync(uri, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, json);
    } finally {
      fs.closeSync(f.fd);
    }
    Logger.i(`备份已导出 歌单=${out.length} 收藏=${favorites.length} ${json.length} 字节`);
    return `${out.length} 个歌单 · ${favorites.length} 首收藏`;
  }

  async importFrom(uri: string): Promise<RestoreResult> {
    const fail = (message: string): RestoreResult => {
      return { ok: false, message: message, playlists: 0, favorites: 0 };
    };

    let text = '';
    try {
      text = this.readAll(uri);
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`读取备份失败 ${err.code}: ${err.message}`);
      return fail(`读取文件失败 ${err.code}`);
    }
    if (text.length === 0) {
      return fail('文件是空的');
    }

    let file: BackupFile | null = null;
    try {
      file = JSON.parse(text) as BackupFile;
    } catch (e) {
      return fail('不是有效的备份文件');
    }
    if (file === null || file === undefined) {
      return fail('不是有效的备份文件');
    }
    if (file.app !== APP_TAG) {
      return fail('这不是 MEMI 輕音的备份');
    }

    let listCount = 0;
    if (Array.isArray(file.playlists)) {
      for (let i = 0; i < file.playlists.length; i++) {
        const p = file.playlists[i];
        if (p === null || p === undefined || typeof p.name !== 'string') {
          continue;
        }
        const id = typeof p.id === 'string' && p.id.length > 0 ? p.id : `bk_${Date.now()}_${i}`;
        const list = new Playlist(id, p.name, typeof p.createdAt === 'number' ? p.createdAt : Date.now());
        if (Array.isArray(p.paths)) {
          for (let j = 0; j < p.paths.length; j++) {
            if (typeof p.paths[j] === 'string' && p.paths[j].length > 0) {
              list.paths.push(p.paths[j]);
            }
          }
        }
        await db.upsertPlaylist(list);
        // 关联表要单独写，upsert 只管歌单本身
        await db.replacePlaylistSongs(id, list.paths);
        listCount++;
      }
    }

    let favCount = 0;
    if (Array.isArray(file.favorites)) {
      for (let i = 0; i < file.favorites.length; i++) {
        const p = file.favorites[i];
        if (typeof p === 'string' && p.length > 0) {
          await db.addFavorite(p);
          favCount++;
        }
      }
    }

    if (typeof file.settings === 'string' && file.settings.length > 0) {
      await settings.importJson(file.settings);
    }

    Logger.i(`备份已恢复 歌单=${listCount} 收藏=${favCount}`);
    return {
      ok: true,
      message: `已恢复 ${listCount} 个歌单 · ${favCount} 首收藏`,
      playlists: listCount,
      favorites: favCount
    };
  }

  private readAll(uri: string): string {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const size = fs.statSync(file.fd).size;
      if (size <= 0) {
        return '';
      }
      const buffer = new ArrayBuffer(size);
      fs.readSync(file.fd, buffer);
      const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      return decoder.decodeToString(new Uint8Array(buffer));
    } finally {
      fs.closeSync(file.fd);
    }
  }
}

export const backup: BackupService = new BackupService();
