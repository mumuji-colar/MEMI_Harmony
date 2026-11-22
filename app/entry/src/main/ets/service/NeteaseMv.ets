import { Logger } from '../common/Logger';
import { NeteaseMv, fetchMvStream } from './NeteaseApi';

@ObservedV2
export class MvState {
  @Trace open: boolean = false;
  @Trace loading: boolean = false;
  @Trace mvId: number = 0;
  @Trace title: string = '';
  @Trace artist: string = '';
  @Trace coverUrl: string = '';
  @Trace url: string = '';
  @Trace quality: string = '';
  @Trace durationMs: number = 0;
  @Trace message: string = '';
}

/**
 * MV 播放。
 * 播放地址从 /api/mv/detail 的 brs 里取最高档；老的 /api/mv/url 已下线。
 */
export class NeteaseMvService {
  readonly state: MvState = new MvState();
  private seq: number = 0;

  async open(mv: NeteaseMv): Promise<void> {
    if (mv.id <= 0) {
      return;
    }
    this.seq++;
    const mine = this.seq;
    this.state.open = true;
    this.state.loading = true;
    this.state.mvId = mv.id;
    this.state.title = mv.name;
    this.state.artist = mv.artistName;
    this.state.coverUrl = mv.coverUrl;
    this.state.url = '';
    this.state.quality = '';
    this.state.durationMs = mv.durationMs;
    this.state.message = '';
    try {
      const stream = await fetchMvStream(mv.id);
      if (mine !== this.seq) {
        return;
      }
      if (stream.url.length === 0) {
        this.state.message = '没有可用的 MV 地址（可能需要会员或已下架）';
        return;
      }
      this.state.url = stream.url;
      this.state.quality = stream.quality;
      this.state.coverUrl = stream.coverUrl.length > 0 ? stream.coverUrl : this.state.coverUrl;
      if (stream.artistName.length > 0) {
        this.state.artist = stream.artistName;
      }
      if (stream.durationMs > 0) {
        this.state.durationMs = stream.durationMs;
      }
      Logger.i(`MV 地址已解析 ${mv.id} ${stream.quality}`);
    } catch (e) {
      if (mine === this.seq) {
        this.state.message = `MV 加载失败 ${(e as Error).message}`;
        Logger.w(`MV 加载失败 ${(e as Error).message}`);
      }
    } finally {
      if (mine === this.seq) {
        this.state.loading = false;
      }
    }
  }

  close(): void {
    this.state.open = false;
    this.state.url = '';
    this.seq++;
  }
}

export const neteaseMv = new NeteaseMvService();
