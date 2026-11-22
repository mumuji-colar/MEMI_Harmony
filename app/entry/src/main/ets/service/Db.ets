import { relationalStore } from '@kit.ArkData';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Song } from '../model/Song';
import { DownloadTask } from '../model/DownloadTask';
import { Playlist } from '../model/Playlist';
import { Logger } from '../common/Logger';

const DB_NAME: string = 'memi.db';
const LEGACY_STORE: string = 'memi_store';
const LEGACY_LIBRARY: string = 'library_json';
const LEGACY_PLAYLISTS: string = 'playlists_json';

const SQL_SONG: string = `CREATE TABLE IF NOT EXISTS song (
  path TEXT PRIMARY KEY,
  file_name TEXT NOT NULL,
  title TEXT NOT NULL,
  artist TEXT NOT NULL,
  album TEXT NOT NULL,
  duration_ms INTEGER NOT NULL,
  size_bytes INTEGER NOT NULL,
  mime_type TEXT NOT NULL,
  added_at INTEGER NOT NULL
)`;

const SQL_PLAYLIST: string = `CREATE TABLE IF NOT EXISTS playlist (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  created_at INTEGER NOT NULL
)`;

const SQL_PLAYLIST_SONG: string = `CREATE TABLE IF NOT EXISTS playlist_song (
  playlist_id TEXT NOT NULL,
  path TEXT NOT NULL,
  sort_order INTEGER NOT NULL,
  PRIMARY KEY (playlist_id, path)
)`;

/** 收藏 */
const SQL_FAVORITE: string = `CREATE TABLE IF NOT EXISTS favorite (
  path TEXT PRIMARY KEY,
  added_at INTEGER NOT NULL
)`;

/** 每首歌的歌词偏移（毫秒），正数=歌词提前 */
const SQL_LYRIC_OFFSET: string = `CREATE TABLE IF NOT EXISTS lyric_offset (
  path TEXT PRIMARY KEY,
  offset_ms INTEGER NOT NULL
)`;

/** 播放历史，为「最近播放」和统计预留 */
const SQL_HISTORY: string = `CREATE TABLE IF NOT EXISTS play_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  path TEXT NOT NULL,
  title TEXT NOT NULL,
  played_at INTEGER NOT NULL
)`;

/**
 * 在线曲目元数据。
 * 在线歌不在本地曲库里，但收藏、自建歌单、上次播放都只存 path，
 * 所以被引用到的在线曲目要把标题/歌手/封面留一份，否则重启后这些引用就成了空路径。
 */
const SQL_REMOTE_SONG: string = `CREATE TABLE IF NOT EXISTS remote_song (
  path TEXT PRIMARY KEY,
  remote_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  artist TEXT NOT NULL,
  album TEXT NOT NULL,
  duration_ms INTEGER NOT NULL,
  cover_url TEXT NOT NULL,
  artist_id INTEGER NOT NULL DEFAULT 0,
  added_at INTEGER NOT NULL
)`;

/** 下载任务 */
const SQL_DOWNLOAD: string = `CREATE TABLE IF NOT EXISTS download_task (
  song_path TEXT PRIMARY KEY,
  remote_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  artist TEXT NOT NULL,
  album TEXT NOT NULL,
  artist_id INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER NOT NULL,
  cover_url TEXT NOT NULL,
  quality TEXT NOT NULL,
  level TEXT NOT NULL DEFAULT '',
  file_path TEXT NOT NULL,
  total_bytes INTEGER NOT NULL,
  downloaded_bytes INTEGER NOT NULL,
  status INTEGER NOT NULL,
  created_at INTEGER NOT NULL
)`;

/** 最常听的一行 */
export class StatsRow {
  path: string = '';
  count: number = 0;
}

/** 某天播放了多少次 */
export class StatsDay {
  /** 形如 2026-11-22 */
  day: string = '';
  count: number = 0;
}

interface LegacySong {
  path: string;
  fileName: string;
  title: string;
  artist: string;
  album: string;
  durationMs: number;
  sizeBytes: number;
  mimeType: string;
}

interface LegacyPlaylist {
  id: string;
  name: string;
  paths: string[];
  createdAt: number;
}

/**
 * 关系型数据库。曲库、歌单、播放历史都放这里。
 *
 * 之前用 preferences 存整段 JSON，几百首还行，上千首每次改动都要全量序列化 + 反序列化，
 * 启动会明显卡；换成 RDB 后按行读写，后面加「最近播放」「收藏」「统计」也不必再换一次地基。
 *
 * 旧数据会在初始化时从 preferences 迁移过来一次（见 migrateFromPreferences）。
 */
export class Db {
  private store: relationalStore.RdbStore | null = null;
  private inited: boolean = false;

  async init(ctx: common.UIAbilityContext): Promise<void> {
    if (this.inited) {
      return;
    }
    try {
      const config: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      this.store = await relationalStore.getRdbStore(ctx, config);
      await this.store.executeSql(SQL_SONG);
      await this.store.executeSql(SQL_PLAYLIST);
      await this.store.executeSql(SQL_PLAYLIST_SONG);
      await this.store.executeSql(SQL_HISTORY);
      await this.store.executeSql(SQL_FAVORITE);
      await this.store.executeSql(SQL_LYRIC_OFFSET);
      await this.store.executeSql(SQL_REMOTE_SONG);
      await this.store.executeSql(SQL_DOWNLOAD);
      // 老库没有 artist_id，补一列；已存在时 ALTER 会报错，忽略即可
      try {
        await this.store.executeSql(
          'ALTER TABLE remote_song ADD COLUMN artist_id INTEGER NOT NULL DEFAULT 0');
      } catch (e) {
        // 列已存在
      }
      this.inited = true;
      Logger.i('RDB 初始化完成');
      await this.migrateFromPreferences(ctx);
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`RDB 初始化失败 ${err.code}: ${err.message}`);
    }
  }

  private get ready(): relationalStore.RdbStore | null {
    return this.store;
  }

  // ---------- 曲库 ----------

  /** 整库替换：先清空再批量插入，放在一个事务里 */
  async replaceLibrary(songs: Song[]): Promise<void> {
    const s = this.ready;
    if (s === null) {
      return;
    }
    try {
      s.beginTransaction();
      await s.executeSql('DELETE FROM song');
      const now = Date.now();
      for (let i = 0; i < songs.length; i++) {
        await s.insert('song', this.songBucket(songs[i], now),
          relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
      }
      s.commit();
      Logger.i(`曲库已写入 RDB ${songs.length} 行`);
    } catch (e) {
      s.rollBack();
      const err = e as BusinessError;
      Logger.e(`写曲库失败 ${err.code}: ${err.message}`);
    }
  }

  async loadSongs(): Promise<Song[]> {
    const s = this.ready;
    if (s === null) {
      return [];
    }
    const out: Song[] = [];
    try {
      const rs = await s.querySql(
        'SELECT path, file_name, title, artist, album, duration_ms, size_bytes, mime_type FROM song ORDER BY title COLLATE NOCASE');
      while (rs.goToNextRow()) {
        const song = new Song(rs.getString(0), rs.getString(1));
        song.title = rs.getString(2);
        song.artist = rs.getString(3);
        song.album = rs.getString(4);
        song.durationMs = rs.getLong(5);
        song.sizeBytes = rs.getLong(6);
        song.mimeType = rs.getString(7);
        out.push(song);
      }
      rs.close();
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`读曲库失败 ${err.code}: ${err.message}`);
    }
    return out;
  }

  async songCount(): Promise<number> {
    const s = this.ready;
    if (s === null) {
      return 0;
    }
    try {
      const rs = await s.querySql('SELECT COUNT(*) FROM song');
      let n = 0;
      if (rs.goToNextRow()) {
        n = rs.getLong(0);
      }
      rs.close();
      return n;
    } catch (e) {
      return 0;
    }
  }

  // ---------- 在线曲目元数据 ----------

  /** 收藏/加入歌单时把在线曲目记一份，之后按 path 就能还原 */
  async saveRemoteSong(song: Song): Promise<void> {
    const s = this.ready;
    if (s === null || !song.isRemote() || song.remoteId <= 0) {
      return;
    }
    try {
      const bucket: relationalStore.ValuesBucket = {
        'path': song.path,
        'remote_id': song.remoteId,
        'title': song.title,
        'artist': song.artist,
        'album': song.album,
        'duration_ms': song.durationMs,
        'cover_url': song.coverUrl,
        'artist_id': song.artistId,
        'added_at': Date.now()
      };
      await s.insert('remote_song', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`写在线曲目失败 ${err.code}: ${err.message}`);
    }
  }

  /** 启动时把全部在线曲目读进内存，收藏/歌单还原要用 */
  async loadRemoteSongs(): Promise<Song[]> {
    const s = this.ready;
    if (s === null) {
      return [];
    }
    const out: Song[] = [];
    try {
      const rs = await s.querySql(
        'SELECT path, remote_id, title, artist, album, duration_ms, cover_url, artist_id FROM remote_song');
      while (rs.goToNextRow()) {
        const song = new Song(rs.getString(0), '');
        song.source = 'netease';
        song.remoteId = rs.getLong(1);
        song.title = rs.getString(2);
        song.artist = rs.getString(3);
        song.album = rs.getString(4);
        song.durationMs = rs.getLong(5);
        song.coverUrl = rs.getString(6);
        song.artistId = rs.getLong(7);
        out.push(song);
      }
      rs.close();
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`读在线曲目失败 ${err.code}: ${err.message}`);
    }
    return out;
  }

  // ---------- 下载任务 ----------

  async loadDownloadTasks(): Promise<DownloadTask[]> {
    const s = this.ready;
    if (s === null) {
      return [];
    }
    const out: DownloadTask[] = [];
    try {
      const rs = await s.querySql(
        'SELECT song_path, remote_id, title, artist, album, artist_id, duration_ms, cover_url, '
          + 'quality, level, file_path, total_bytes, downloaded_bytes, status, created_at '
          + 'FROM download_task ORDER BY created_at DESC');
      while (rs.goToNextRow()) {
        const t = new DownloadTask();
        t.songPath = rs.getString(0);
        t.remoteId = rs.getLong(1);
        t.title = rs.getString(2);
        t.artist = rs.getString(3);
        t.album = rs.getString(4);
        t.artistId = rs.getLong(5);
        t.durationMs = rs.getLong(6);
        t.coverUrl = rs.getString(7);
        t.quality = rs.getString(8);
        t.level = rs.getString(9);
        t.filePath = rs.getString(10);
        t.totalBytes = rs.getLong(11);
        t.downloadedBytes = rs.getLong(12);
        t.status = rs.getLong(13);
        t.createdAt = rs.getLong(14);
        out.push(t);
      }
      rs.close();
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`读下载任务失败 ${err.code}: ${err.message}`);
    }
    return out;
  }

  async saveDownloadTask(task: DownloadTask): Promise<void> {
    const s = this.ready;
    if (s === null) {
      return;
    }
    try {
      const bucket: relationalStore.ValuesBucket = {
        'song_path': task.songPath,
        'remote_id': task.remoteId,
        'title': task.title,
        'artist': task.artist,
        'album': task.album,
        'artist_id': task.artistId,
        'duration_ms': task.durationMs,
        'cover_url': task.coverUrl,
        'quality': task.quality,
        'level': task.level,
        'file_path': task.filePath,
        'total_bytes': task.totalBytes,
        'downloaded_bytes': task.downloadedBytes,
        'status': task.status,
        'created_at': task.createdAt
      };
      await s.insert('download_task', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`写下载任务失败 ${err.code}: ${err.message}`);
    }
  }

  async deleteDownloadTask(songPath: string): Promise<void> {
    const s = this.ready;
    if (s === null) {
      return;
    }
    try {
      await s.executeSql('DELETE FROM download_task WHERE song_path = ?', [songPath]);
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`删除下载任务失败 ${err.code}: ${err.message}`);
    }
  }

  // ---------- 歌单 ----------

  async loadPlaylists(): Promise<Playlist[]> {
    const s = this.ready;
    if (s === null) {
      return [];
    }
    const lists: Playlist[] = [];
    try {
      const rs = await s.querySql('SELECT id, name, created_at FROM playlist ORDER BY created_at ASC');
      while (rs.goToNextRow()) {
        lists.push(new Playlist(rs.getString(0), rs.getString(1), rs.getLong(2)));
      }
      rs.close();

      for (let i = 0; i < lists.length; i++) {
        const paths: string[] = [];
        const pr = await s.querySql(
          'SELECT path FROM playlist_song WHERE playlist_id = ? ORDER BY sort_order ASC', [lists[i].id]);
        while (pr.goToNextRow()) {
          paths.push(pr.getString(0));
        }
        pr.close();
        lists[i].paths = paths;
      }
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`读歌单失败 ${err.code}: ${err.message}`);
    }
    return lists;
  }

  async upsertPlaylist(list: Playlist): Promise<void> {
    const s = this.ready;
    if (s === null) {
      return;
    }
    try {
      const bucket: relationalStore.ValuesBucket = {
        'id': list.id,
        'name': list.name,
        'created_at': list.createdAt
      };
      await s.insert('playlist', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`写歌单失败 ${err.code}: ${err.message}`);
    }
  }

  async deletePlaylist(id: string): Promise<void> {
    const s = this.ready;
    if (s === null) {
      return;
    }
    try {
      await s.executeSql('DELETE FROM playlist_song WHERE playlist_id = ?', [id]);
      await s.executeSql('DELETE FROM playlist WHERE id = ?', [id]);
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`删歌单失败 ${err.code}: ${err.message}`);
    }
  }

  async addPlaylistSong(listId: string, path: string, order: number): Promise<void> {
    const s = this.ready;
    if (s === null) {
      return;
    }
    try {
      const bucket: relationalStore.ValuesBucket = {
        'playlist_id': listId,
        'path': path,
        'sort_order': order
      };
      await s.insert('playlist_song', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`加歌到歌单失败 ${err.code}: ${err.message}`);
    }
  }

  /**
   * 覆盖式重写某个歌单的曲目 —— 备份恢复用。
   * upsertPlaylist 只写歌单表本身，不写关联表，漏掉这一步恢复出来会是空歌单。
   */
  async replacePlaylistSongs(listId: string, paths: string[]): Promise<void> {
    const s = this.ready;
    if (s === null) {
      return;
    }
    try {
      await s.executeSql('DELETE FROM playlist_song WHERE playlist_id = ?', [listId]);
      for (let i = 0; i < paths.length; i++) {
        await this.addPlaylistSong(listId, paths[i], i);
      }
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`重写歌单曲目失败 ${err.code}: ${err.message}`);
    }
  }

  async removePlaylistSong(listId: string, path: string): Promise<void> {
    const s = this.ready;
    if (s === null) {
      return;
    }
    try {
      await s.executeSql('DELETE FROM playlist_song WHERE playlist_id = ? AND path = ?', [listId, path]);
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`从歌单移除失败 ${err.code}: ${err.message}`);
    }
  }

  // ---------- 收藏 ----------

  async favoritePaths(): Promise<string[]> {
    const s = this.ready;
    if (s === null) {
      return [];
    }
    const out: string[] = [];
    try {
      const rs = await s.querySql('SELECT path FROM favorite ORDER BY added_at DESC');
      while (rs.goToNextRow()) {
        out.push(rs.getString(0));
      }
      rs.close();
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`读收藏失败 ${err.code}`);
    }
    return out;
  }

  async addFavorite(path: string): Promise<void> {
    const s = this.ready;
    if (s === null) {
      return;
    }
    try {
      const bucket: relationalStore.ValuesBucket = {
        'path': path,
        'added_at': Date.now()
      };
      await s.insert('favorite', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`收藏失败 ${err.code}`);
    }
  }

  async removeFavorite(path: string): Promise<void> {
    const s = this.ready;
    if (s === null) {
      return;
    }
    try {
      await s.executeSql('DELETE FROM favorite WHERE path = ?', [path]);
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`取消收藏失败 ${err.code}`);
    }
  }

  // ---------- 歌词偏移 ----------

  async loadLyricOffset(path: string): Promise<number> {
    const s = this.ready;
    if (s === null || path.length === 0) {
      return 0;
    }
    try {
      const rs = await s.querySql('SELECT offset_ms FROM lyric_offset WHERE path = ?', [path]);
      let v = 0;
      if (rs.goToNextRow()) {
        v = rs.getLong(0);
      }
      rs.close();
      return v;
    } catch (e) {
      return 0;
    }
  }

  async saveLyricOffset(path: string, offsetMs: number): Promise<void> {
    const s = this.ready;
    if (s === null || path.length === 0) {
      return;
    }
    try {
      if (offsetMs === 0) {
        await s.executeSql('DELETE FROM lyric_offset WHERE path = ?', [path]);
        return;
      }
      const bucket: relationalStore.ValuesBucket = {
        'path': path,
        'offset_ms': offsetMs
      };
      await s.insert('lyric_offset', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`保存歌词偏移失败 ${err.code}`);
    }
  }

  // ---------- 播放历史 ----------

  async recordPlay(path: string, title: string): Promise<void> {
    const s = this.ready;
    if (s === null || path.length === 0) {
      return;
    }
    try {
      const bucket: relationalStore.ValuesBucket = {
        'path': path,
        'title': title,
        'played_at': Date.now()
      };
      await s.insert('play_history', bucket);
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`记录播放历史失败 ${err.code}`);
    }
  }

  /** 最近播放的路径，去重后按时间倒序 */
  async recentPaths(limit: number): Promise<string[]> {
    const s = this.ready;
    if (s === null) {
      return [];
    }
    const out: string[] = [];
    try {
      const rs = await s.querySql(
        'SELECT path FROM play_history GROUP BY path ORDER BY MAX(played_at) DESC LIMIT ?', [limit]);
      while (rs.goToNextRow()) {
        out.push(rs.getString(0));
      }
      rs.close();
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`读最近播放失败 ${err.code}`);
    }
    return out;
  }


  // ---------- 播放统计 ----------

  /** 累计播放次数、听过的不同曲目数 */
  async statsTotals(): Promise<number[]> {
    const st = this.ready;
    if (st === null) {
      return [0, 0];
    }
    try {
      const rs = await st.querySql('SELECT COUNT(*), COUNT(DISTINCT path) FROM play_history');
      let a = 0;
      let b = 0;
      if (rs.goToNextRow()) {
        a = rs.getLong(0);
        b = rs.getLong(1);
      }
      rs.close();
      return [a, b];
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`读统计总数失败 ${err.code}`);
      return [0, 0];
    }
  }

  /** 最常听：路径 + 次数，按次数倒序 */
  async statsTop(limit: number): Promise<StatsRow[]> {
    const st = this.ready;
    if (st === null) {
      return [];
    }
    const out: StatsRow[] = [];
    try {
      const rs = await st.querySql(
        'SELECT path, COUNT(*) FROM play_history GROUP BY path ORDER BY COUNT(*) DESC, MAX(played_at) DESC LIMIT ?',
        [limit]);
      while (rs.goToNextRow()) {
        const row = new StatsRow();
        row.path = rs.getString(0);
        row.count = rs.getLong(1);
        out.push(row);
      }
      rs.close();
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`读最常听失败 ${err.code}`);
    }
    return out;
  }

  /** 按天统计最近 N 天的播放次数，返回 [毫秒时间戳(当天0点), 次数] */
  async statsByDay(days: number): Promise<StatsDay[]> {
    const st = this.ready;
    if (st === null) {
      return [];
    }
    const out: StatsDay[] = [];
    try {
      // 用本地时区分天；played_at 是毫秒
      const rs = await st.querySql(
        `SELECT date(played_at / 1000, 'unixepoch', 'localtime') AS d, COUNT(*)
         FROM play_history
         WHERE played_at >= ?
         GROUP BY d ORDER BY d ASC`, [Date.now() - days * 86400000]);
      while (rs.goToNextRow()) {
        const row = new StatsDay();
        row.day = rs.getString(0);
        row.count = rs.getLong(1);
        out.push(row);
      }
      rs.close();
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`读每日统计失败 ${err.code}`);
    }
    return out;
  }

  /** 首次播放时间，用来算「陪你 X 天」 */
  async firstPlayAt(): Promise<number> {
    const st = this.ready;
    if (st === null) {
      return 0;
    }
    try {
      const rs = await st.querySql('SELECT MIN(played_at) FROM play_history');
      let v = 0;
      if (rs.goToNextRow() && !rs.isColumnNull(0)) {
        v = rs.getLong(0);
      }
      rs.close();
      return v;
    } catch (e) {
      return 0;
    }
  }

  async clearHistory(): Promise<void> {
    const st = this.ready;
    if (st === null) {
      return;
    }
    try {
      await st.executeSql('DELETE FROM play_history');
      Logger.i('播放历史已清空');
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`清空历史失败 ${err.code}`);
    }
  }

  // ---------- 内部 ----------

  private songBucket(song: Song, addedAt: number): relationalStore.ValuesBucket {
    const bucket: relationalStore.ValuesBucket = {
      'path': song.path,
      'file_name': song.fileName,
      'title': song.title,
      'artist': song.artist,
      'album': song.album,
      'duration_ms': song.durationMs,
      'size_bytes': song.sizeBytes,
      'mime_type': song.mimeType,
      'added_at': addedAt
    };
    return bucket;
  }

  /**
   * 从旧的 preferences JSON 迁移一次。
   * 只在 song 表为空时执行，避免覆盖用户新数据。
   */
  private async migrateFromPreferences(ctx: common.UIAbilityContext): Promise<void> {
    const s = this.ready;
    if (s === null) {
      return;
    }
    try {
      const count = await this.songCount();
      if (count > 0) {
        return;
      }
      const store = await preferences.getPreferences(ctx, LEGACY_STORE);
      const rawLib = (await store.get(LEGACY_LIBRARY, '')) as string;
      if (rawLib.length === 0) {
        return;
      }
      const records = JSON.parse(rawLib) as LegacySong[];
      const songs: Song[] = [];
      for (let i = 0; i < records.length; i++) {
        const r = records[i];
        const song = new Song(r.path, r.fileName);
        song.title = r.title;
        song.artist = r.artist;
        song.album = r.album;
        song.durationMs = r.durationMs;
        song.sizeBytes = r.sizeBytes;
        song.mimeType = r.mimeType;
        songs.push(song);
      }
      await this.replaceLibrary(songs);
      Logger.i(`已从 preferences 迁移曲库 ${songs.length} 首`);

      const rawList = (await store.get(LEGACY_PLAYLISTS, '')) as string;
      if (rawList.length > 0) {
        const lists = JSON.parse(rawList) as LegacyPlaylist[];
        for (let i = 0; i < lists.length; i++) {
          const l = lists[i];
          const p = new Playlist(l.id, l.name, l.createdAt);
          await this.upsertPlaylist(p);
          for (let j = 0; j < l.paths.length; j++) {
            await this.addPlaylistSong(l.id, l.paths[j], j);
          }
        }
        Logger.i(`已从 preferences 迁移歌单 ${lists.length} 个`);
      }

      // 迁移完就把旧键清掉，避免下次重复判断
      await store.delete(LEGACY_LIBRARY);
      await store.delete(LEGACY_PLAYLISTS);
      await store.flush();
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`迁移旧数据失败 ${err.code}: ${err.message}`);
    }
  }
}

export const db: Db = new Db();
