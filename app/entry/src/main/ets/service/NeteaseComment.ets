import { Song } from '../model/Song';
import { Logger } from '../common/Logger';
import { NeteaseComment, fetchComments } from './NeteaseApi';

/** 评论排序 */
export enum CommentSort {
  HOT = 2,
  NEW = 3
}

const PAGE_SIZE: number = 20;

@ObservedV2
export class CommentState {
  @Trace open: boolean = false;
  @Trace loading: boolean = false;
  @Trace loadingMore: boolean = false;
  @Trace songId: number = 0;
  @Trace title: string = '';
  @Trace total: number = 0;
  @Trace sort: number = CommentSort.HOT;
  @Trace comments: NeteaseComment[] = [];
  @Trace hasMore: boolean = false;
  @Trace message: string = '';
}

/**
 * 歌曲评论（只读）。
 *
 * 发评论/点赞需要 yidun 校验令牌（createNEFingerprint 的另一路），
 * 这里先只做浏览：热门 + 最新 + 翻页。
 */
export class NeteaseCommentService {
  readonly state: CommentState = new CommentState();
  private pageNo: number = 1;
  private cursor: string = '';
  private seq: number = 0;

  async open(song: Song): Promise<void> {
    if (!song.isRemote() || song.remoteId <= 0) {
      return;
    }
    this.seq++;
    this.state.open = true;
    this.state.songId = song.remoteId;
    this.state.title = song.title;
    this.state.comments = [];
    this.state.total = 0;
    this.state.hasMore = false;
    this.state.message = '';
    this.state.sort = CommentSort.HOT;
    this.pageNo = 1;
    this.cursor = 'normalHot#0';
    await this.load(true, this.seq);
  }

  close(): void {
    this.state.open = false;
    this.seq++;
  }

  async setSort(sort: number): Promise<void> {
    if (this.state.sort === sort) {
      return;
    }
    this.state.sort = sort;
    this.pageNo = 1;
    this.cursor = sort === CommentSort.NEW ? '0' : 'normalHot#0';
    this.state.comments = [];
    this.state.hasMore = false;
    this.seq++;
    await this.load(true, this.seq);
  }

  async loadMore(): Promise<void> {
    if (!this.state.hasMore || this.state.loading || this.state.loadingMore) {
      return;
    }
    this.pageNo++;
    await this.load(false, this.seq);
  }

  private async load(reset: boolean, mine: number): Promise<void> {
    if (reset) {
      this.state.loading = true;
    } else {
      this.state.loadingMore = true;
    }
    try {
      const page = await fetchComments(this.state.songId, this.pageNo, PAGE_SIZE,
        this.state.sort, this.cursor);
      if (mine !== this.seq) {
        return;
      }
      if (reset) {
        this.state.comments = page.comments;
      } else {
        for (let i = 0; i < page.comments.length; i++) {
          this.state.comments.push(page.comments[i]);
        }
        this.state.comments = this.state.comments.slice();
      }
      if (page.total > 0) {
        this.state.total = page.total;
      }
      this.state.hasMore = page.hasMore;
      this.cursor = page.cursor;
      this.state.message = this.state.comments.length === 0 ? '还没有评论' : '';
    } catch (e) {
      if (mine === this.seq) {
        this.state.message = `评论加载失败 ${(e as Error).message}`;
        Logger.w(`评论加载失败 ${(e as Error).message}`);
      }
    } finally {
      if (mine === this.seq) {
        this.state.loading = false;
        this.state.loadingMore = false;
      }
    }
  }
}

export const neteaseComment = new NeteaseCommentService();
