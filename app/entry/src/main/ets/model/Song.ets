/** 一首歌在内存里的样子。字段名尽量对齐源项目 Android 版的 Song 模型。 */
export class Song {
  /** 文件系统路径，播放时直接喂给 fs.open；在线曲目是 netease://<id> 形式的稳定标识 */
  path: string = '';
  /** 文件名（不带目录）；在线曲目为空 */
  fileName: string = '';
  /** 标签里的标题，没标签时回落成文件名（去扩展名） */
  title: string = '';
  artist: string = '';
  album: string = '';
  durationMs: number = 0;
  sizeBytes: number = 0;
  mimeType: string = '';

  /** 曲目来源：local = 本地导入，netease = 网易云在线 */
  source: string = 'local';
  /** 在线曲目在原站的数字 ID，本地曲目为 0 */
  remoteId: number = 0;
  /** 第一位歌手的 ID，用于打开艺人主页；本地曲目或未知为 0 */
  artistId: number = 0;
  /** 在线封面地址，列表与播放页直接交给 Image 组件加载 */
  coverUrl: string = '';
  /** 在线音质提示，如 "320k mp3"，用于列表副标题 */
  quality: string = '';

  constructor(path: string, fileName: string) {
    this.path = path;
    this.fileName = fileName;
  }

  /** 是否在线曲目（播放前需要先解析出真实音频地址） */
  isRemote(): boolean {
    return this.source !== 'local';
  }
}
