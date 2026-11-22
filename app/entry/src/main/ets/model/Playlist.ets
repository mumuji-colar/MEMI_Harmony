/** 一个自建歌单 */
export class Playlist {
  id: string = '';
  name: string = '';
  /** 只存歌曲路径，不存副本 —— 曲库移除某首时歌单里自然失效 */
  paths: string[] = [];
  createdAt: number = 0;

  constructor(id: string, name: string, createdAt: number) {
    this.id = id;
    this.name = name;
    this.createdAt = createdAt;
  }
}
