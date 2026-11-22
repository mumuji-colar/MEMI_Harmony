import { common } from '@kit.AbilityKit';
import { Playlist } from '../model/Playlist';
import { library } from './LibraryService';
import { Song } from '../model/Song';
import { Logger } from '../common/Logger';
import { db } from './Db';

const STORE_NAME: string = 'memi_store';

@ObservedV2
export class PlaylistState {
  @Trace lists: Playlist[] = [];
  /** 每次歌单内容变化 +1，UI 靠它刷新 */
  @Trace version: number = 0;
}

/**
 * 自建歌单。
 *
 * 只存路径不存副本：曲库移除某首歌后，歌单里那一条会因为找不到 Song 而自动不显示，
 * 但路径还留着——用户把歌加回曲库，歌单立刻恢复，不会莫名其妙丢内容。
 */
export class PlaylistService {
  readonly state: PlaylistState = new PlaylistState();
  private inited: boolean = false;

  async init(ctx: common.UIAbilityContext): Promise<void> {
    if (this.inited) {
      return;
    }
    this.inited = true;
    await this.reload();
  }

  /** 从数据库重读，备份恢复之后要刷新一次 */
  async reload(): Promise<void> {
    const lists = await db.loadPlaylists();
    this.state.lists = lists;
    this.state.version++;
    Logger.i(`歌单已从 RDB 读取 ${lists.length} 个`);
  }

  /** 新建歌单，返回新歌单 id */
  create(name: string): string {
    const id = `${Date.now()}`;
    const clean = name.trim().length > 0 ? name.trim() : `歌单 ${this.state.lists.length + 1}`;
    const list = new Playlist(id, clean, Date.now());
    const next = this.state.lists.slice();
    next.push(list);
    this.state.lists = next;
    this.state.version++;
    db.upsertPlaylist(list);
    Logger.i(`新建歌单 ${clean}`);
    return id;
  }

  removeList(id: string): void {
    const next = this.state.lists.filter((p: Playlist) => p.id !== id);
    if (next.length === this.state.lists.length) {
      return;
    }
    this.state.lists = next;
    this.state.version++;
    db.deletePlaylist(id);
  }

  rename(id: string, name: string): void {
    const clean = name.trim();
    if (clean.length === 0) {
      return;
    }
    const list = this.find(id);
    if (list === null) {
      return;
    }
    list.name = clean;
    this.state.version++;
    db.upsertPlaylist(list);
  }

  find(id: string): Playlist | null {
    for (let i = 0; i < this.state.lists.length; i++) {
      if (this.state.lists[i].id === id) {
        return this.state.lists[i];
      }
    }
    return null;
  }

  /** 加歌，重复加会忽略 */
  addSong(id: string, path: string): boolean {
    const list = this.find(id);
    if (list === null) {
      return false;
    }
    if (list.paths.indexOf(path) >= 0) {
      return false;
    }
    list.paths.push(path);
    this.state.version++;
    db.addPlaylistSong(id, path, list.paths.length - 1);
    return true;
  }

  /**
   * 按 Song 对象加歌。
   * 在线曲目要先把元数据留在库里，否则重启后这个 path 无法还原成歌。
   */
  addSongEntity(id: string, song: Song): boolean {
    if (song.isRemote()) {
      library.rememberRemote(song);
      db.saveRemoteSong(song);
    }
    return this.addSong(id, song.path);
  }

  removeSong(id: string, path: string): void {
    const list = this.find(id);
    if (list === null) {
      return;
    }
    const next = list.paths.filter((p: string) => p !== path);
    if (next.length === list.paths.length) {
      return;
    }
    list.paths = next;
    this.state.version++;
    db.removePlaylistSong(id, path);
  }

  /** 把路径还原成 Song（曲库里没有的会跳过） */
  songsOf(id: string): Song[] {
    const list = this.find(id);
    if (list === null) {
      return [];
    }
    return library.resolvePaths(list.paths);
  }

}

export const playlists: PlaylistService = new PlaylistService();
