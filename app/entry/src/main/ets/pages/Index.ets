import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { window, display, curves } from '@kit.ArkUI';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { audioPlayer, PlayerState } from '../service/AudioPlayer';
import { playback, PlayMode, PlayModeState } from '../service/PlaybackController';
import { library, LibraryState, GroupItem } from '../service/LibraryService';
import { persist } from '../service/PersistService';
import { lyric, LyricState } from '../service/LyricService';
import { cover, CoverState, ThumbState } from '../service/CoverService';
import { sleepTimer } from '../service/SleepTimer';
import { playlists, PlaylistState } from '../service/PlaylistService';
import { db } from '../service/Db';
import { stats, StatsState, StatsTopItem, StatsDayItem } from '../service/StatsService';
import { settings, SettingsState, ACCENTS, AccentPreset } from '../service/SettingsService';
import { netease, NeteaseState, HomeBlock, HomeBlockKind, HomeBlockState } from '../service/NeteaseService';
import { NeteasePlaylist, NeteaseComment, NeteaseMv } from '../service/NeteaseApi';
import { neteaseArtist, ArtistState, ArtistTab } from '../service/NeteaseArtist';
import { neteaseComment, CommentState, CommentSort } from '../service/NeteaseComment';
import { neteaseMv, MvState } from '../service/NeteaseMv';
import { downloader, DownloadState, formatBytes } from '../service/DownloadService';
import { storage, StorageState } from '../service/StorageService';
import { backup } from '../service/BackupService';
import { DownloadTask, DownloadStatus } from '../model/DownloadTask';
import { neteaseAuth, NeteaseAuthState, QrPhase } from '../service/NeteaseAuth';
import { pasteboard } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { Playlist } from '../model/Playlist';
import { image } from '@kit.ImageKit';
import { cellsForLine, lerpLyricColor, CharCell } from '../common/LyricRender';
import { LyricLine } from '../model/LyricLine';
import { Song } from '../model/Song';
import { Logger } from '../common/Logger';
import { formatTime } from '../common/Format';

const TEXT_MAIN: string = '#F5EDE8';
const TEXT_SUB: string = '#8E8079';
const SPEED_OPTIONS: number[] = [0.5, 1, 1.25, 1.5, 2];


/** 探索页的推荐关键词 */
const EXPLORE_WORDS: string[] = ['华语流行', '摇滚', '电子', '民谣', '影视原声', '爵士', '古典', '说唱', '轻音乐', '游戏配乐'];

@Entry
@ComponentV2
struct Index {
  @Local player: PlayerState = audioPlayer.state;
  @Local lib: LibraryState = library.state;
  @Local mode: PlayModeState = playback.modeState;
  @Local lyrics: LyricState = lyric.state;
  @Local covers: CoverState = cover.state;
  @Local thumbs: ThumbState = cover.thumbState;
  @Local showPlayer: boolean = false;
  @Local showQueue: boolean = false;
  @Local showLyrics: boolean = false;
  /**
   * 页面内镜像的定时分钟数。
   * 直接读 sleepTimer.state.minutes 时变化不会驱动这排按钮重绘
   * （带参 @Builder 的参数在父级求值，而父级没被标记脏），所以在这里存一份。
   */
  @Local sleepMinutes: number = 0;
  /** 页面内镜像的播放模式，理由同上：单例状态不驱动这页重绘 */
  @Local playMode: number = 0;
  /** 关掉随机后回到哪种循环方式（列表 / 单曲） */
  @Local lastLoopMode: number = PlayMode.SEQUENCE;
  /** 页签切换：淡入 + 水平轻推，方向跟着页签顺序 */
  @Local tabFade: number = 1;
  @Local tabShiftX: number = 0;
  /** 设置子页进出：横向推入 */
  @Local settingsFade: number = 1;
  @Local settingsShiftX: number = 0;
  /**
   * 插值后的播放位置。音频进度回调约 0.5 秒一次，直接拿它渲染逐字歌词会一格一格跳；
   * 这里按 Android 版 InterpolatedPlaybackPosition 的做法，用锚点 + 流逝时间预测。
   */
  @Local renderPos: number = 0;
  private posAnchorMs: number = 0;
  private posAnchorAt: number = 0;
  private lastRawPos: number = -1;
  @Local viewMode: number = 0;
  @Local groupKey: string = '';
  /** 媒体库分区：0 本地 / 1 收藏 / 2 下载 */
  @Local libSection: number = 0;
  /** 收藏里的分类：0 歌曲 / 1 专辑 / 2 艺术家 */
  @Local favTab: number = 0;
  /** 下载里的分类：0 已完成 / 1 下载中 */
  @Local dlTab: number = 0;
  /** 收藏按专辑/艺术家下钻时选中的名字 */
  @Local favGroupKey: string = '';
  @Local playlistsState: PlaylistState = playlists.state;
  @Local playlistId: string = '';
  @Local showCreate: boolean = false;
  @Local newName: string = '';
  @Local pickerPath: string = '';
  @Local recentSongs: Song[] = [];
  @Local favoriteSongs: Song[] = [];
  @Local favPaths: string[] = [];
  @Local st: SettingsState = settings.state;
  @Local statsState: StatsState = stats.state;
  @Local online: NeteaseState = netease.state;
  @Local auth: NeteaseAuthState = neteaseAuth.state;
  @Local artistSt: ArtistState = neteaseArtist.state;
  @Local commentSt: CommentState = neteaseComment.state;
  @Local mvSt: MvState = neteaseMv.state;
  @Local dl: DownloadState = downloader.state;
  @Local storageState: StorageState = storage.state;
  /** 备份页的操作反馈 */
  @Local backupMsg: string = '';
  @Local backupBusy: boolean = false;
  /** 艺人简介是否展开 */
  @Local briefOpen: boolean = false;
  /** 在线曲目操作面板 */
  @Local actionOpen: boolean = false;
  @Local actionSong: Song | null = null;
  @Local showLogin: boolean = false;
  /** 登录页 0 扫码 / 1 Cookie */
  @Local loginTab: number = 0;
  /** 风控指纹是否已就绪（扫码前要先用 WebView 取到 ydDeviceToken） */
  @Local fpReady: boolean = false;
  /** 加入歌单时携带的在线曲目对象，本地曲目仍走 pickerPath */
  @Local pickerSong: Song | null = null;
  /** 圆盘旋转角度，播放时持续累加 */
  @Local discAngle: number = 0;
  /** 底部页签：0 首页 / 1 探索 / 2 媒体库 / 3 设置 */
  @Local tab: number = 0;
  /** 设置子页：空串=首页，其余见 settingsTitle() */
  @Local settingsPage: string = '';
  /** 当前这首本地歌曲是否已手动导入歌词（进歌词设置页时同步） */
  @Local lyricImported: boolean = false;
  /** 状态栏 / 导航条的真实高度（vp），沉浸式布局下要自己让开 */
  @Local topInset: number = 36;
  @Local bottomInset: number = 16;
  /** 页面内容区宽度（已扣掉左右内边距与宽屏导航栏），歌单网格按它算格子宽 */
  @Local contentWidth: number = 340;
  /** 窗口宽度（vp）：折叠屏展开、平板分屏、横竖屏切换都会重算 */
  @Local windowW: number = 360;
  /** 宽屏形态：≥600vp 时底部页签换成左侧导航栏 */
  @Local isWide: boolean = false;
  /** 歌单网格列数：跟着内容宽度走，避免宽屏下格子被拉得过大 */
  @Local gridCols: number = 3;
  /** 宽屏左侧导航栏宽度 */
  private railWidth: number = 88;
  /**
   * 宽屏播放页专用尺寸：左屏内容列宽与封面边长。
   * 不跟着全局断点算，因为分栏后每屏只有半幅宽度，
   * 大折叠展开（707vp）和阔折叠（940vp）差得很多。
   */
  @Local wideColW: number = 340;
  @Local wideCover: number = 300;
  /**
   * 竖屏播放页封面边长。
   * 阔折叠外屏这类「矮宽」窗口（460×672）比例接近平板，
   * 封面若按容器撑满就会把进度条和控制键顶出屏幕，所以也要限高。
   */
  @Local narrowCover: number = 340;
  private win: window.Window | null = null;
  /** 窗口尺寸回调；注销时必须用同一个引用 */
  private onWinResize: ((size: window.Size) => void) | null = null;

  private scroller: Scroller = new Scroller();
  /** 宽屏播放页右侧歌词用独立控制器，避免和全屏歌词页抢同一个 List */
  private wideScroller: Scroller = new Scroller();
  private lyricTimer: number = -1;
  private scrolledIndex: number = -1;
  private lyricPath: string = '';
  private thumbToken: number = 0;
  /** 隐藏 WebView：只为执行 createNEFingerprint 取风控指纹，与安卓版同路数 */
  private fpCtl: webview.WebviewController = new webview.WebviewController();
  private fpToken: string = '';
  private fpCookieRaw: string = '';
  private fpDone: boolean = false;
  private fpStarted: boolean = false;
  private fpTimer: number = -1;
  /** MV 播放器（Video 组件用） */
  private videoCtl: VideoController = new VideoController();

  async aboutToAppear(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    // 安全区读取顺带完成断点初始化与窗口尺寸监听
    await this.readSafeArea(ctx);
    // 设置最先读：主题色要在首帧就正确，不能等界面画完再变色
    await settings.init(ctx);
    // 再把数据库开起来，后面的曲库/歌单读取都依赖它
    await db.init(ctx);
    // 下载任务：恢复上次队列，把「下载中」改成「已暂停」
    await downloader.init(ctx);
    // 手动导入的歌词放在沙箱 filesDir/lyrics，先把目录准备好
    lyric.init(ctx);
    // 网易云凭据：有就静默校验一次，顺便把昵称/头像取回来
    await neteaseAuth.init(ctx);
    // 首页推荐启动就拉一次，切到首页时已经有内容；失败页面上有重试
    netease.loadHome();
    netease.ensureExplore();
    neteaseAuth.onLoginSuccess = () => {
      this.showLogin = false;
      netease.resetForAccount();
      this.lib.message = `已登录网易云：${this.auth.nickname}`;
    };
    await playlists.init(ctx);
    // 收藏和自建歌单里可能有在线曲目，先把元数据索引装好
    library.setRemoteSongs(await db.loadRemoteSongs());
    const songs = await persist.loadLibrary(ctx);
    if (songs.length === 0) {
      await this.refreshFavorites();
      return;
    }
    library.restore(songs);
    // 排序方式跟着设置走，重启后保持一致
    library.setSort(settings.state.sortMode);
    this.startThumbQueue();
    // 收藏要在恢复播放之前读，否则没有快照时红心会空
    await this.refreshFavorites();
    // 默认倍速只影响本次启动的初始值，用户随时可改
    audioPlayer.setSpeed(settings.state.defaultSpeed);

    // 恢复上次播到哪首、第几秒；不自动播，等用户点
    if (!settings.state.rememberProgress) {
      return;
    }
    const snap = await persist.loadPlayback(ctx);
    if (snap === null) {
      return;
    }
    // 上次听的是在线曲目时，它不在本地曲库里，从快照重建后补进队列
    const queueSongs: Song[] = songs.slice();
    if (snap.path.startsWith('netease://')) {
      const remoteSong = await persist.loadLastRemoteSong(ctx);
      if (remoteSong !== null && remoteSong.path === snap.path) {
        queueSongs.push(remoteSong);
      }
    }
    playback.setQueue(queueSongs);
    playback.setMode(snap.mode as PlayMode);
    playback.restorePosition(snap.path, snap.positionMs, settings.state.autoResume);
  }

  /**
   * 系统返回键：按浮层层级逐层关闭。
   * 之前没有处理，在设置子页按返回会直接把应用退到后台。
   */
  onBackPress(): boolean {
    if (this.mvSt.open) {
      this.closeMv();
      return true;
    }
    if (this.actionOpen) {
      this.closeSongActions();
      return true;
    }
    if (this.commentSt.open) {
      neteaseComment.close();
      return true;
    }
    if (this.artistSt.open) {
      neteaseArtist.close();
      return true;
    }
    if (this.showLogin) {
      this.closeLogin();
      return true;
    }
    if (this.online.detailOpen) {
      netease.closeDetail();
      return true;
    }
    // 队列现在压在歌词页上面，返回时也要先收它
    if (this.showQueue) {
      this.showQueue = false;
      return true;
    }
    if (this.showLyrics) {
      this.showLyrics = false;
      return true;
    }
    if (this.showPlayer) {
      this.closePlayer();
      return true;
    }
    // 设置子页先退回设置首页
    if (this.tab === 3 && this.settingsPage.length > 0) {
      this.settingsPage = '';
      return true;
    }
    // 其它页签先回首页，再按一次才退出应用
    if (this.tab !== 0) {
      this.tab = 0;
      return true;
    }
    return false;
  }

  aboutToDisappear(): void {
    this.stopLyricTicker();
    if (this.win !== null && this.onWinResize !== null) {
      try {
        this.win.off('windowSizeChange', this.onWinResize);
      } catch (e) {
        Logger.w('注销窗口尺寸监听失败');
      }
      this.onWinResize = null;
    }
  }

  /**
   * 读取状态栏 / 导航条占用高度。
   * 沉浸式布局下窗口铺满全屏，页面得自己把这些区域让开，
   * 否则标题会钻到状态栏底下、播放条会压住手势条。
   */
  private async readSafeArea(ctx: common.UIAbilityContext): Promise<void> {
    try {
      const win = await window.getLastWindow(ctx);
      this.win = win;
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.topInset = px2vp(sys.topRect.height);

      // TYPE_SYSTEM 的 bottom 在全面屏手势下经常是 0，
      // 手势条的实际高度要去 TYPE_NAVIGATION_INDICATOR 拿
      let bottom = px2vp(sys.bottomRect.height);
      try {
        const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        const navBottom = px2vp(nav.bottomRect.height);
        if (navBottom > bottom) {
          bottom = navBottom;
        }
      } catch (e) {
        Logger.w('读导航条安全区失败');
      }
      // 兜底：至少留一点，免得播放条压在手势条上
      this.bottomInset = bottom > 6 ? bottom : 10;
      Logger.i(`安全区 top=${this.topInset.toFixed(0)}vp bottom=${this.bottomInset.toFixed(0)}vp`);

      // 断点与内容宽度：折叠屏展开 / 平板分屏 / 旋转都会重新触发
      const rect = win.getWindowProperties().windowRect;
      this.applyWindowWidth(rect.width, rect.height);
      this.onWinResize = (size: window.Size) => {
        this.applyWindowWidth(size.width, size.height);
      };
      win.on('windowSizeChange', this.onWinResize);
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`读安全区失败 ${err.code}，用默认值`);
      // 拿不到窗口就退回整屏宽度，至少让断点和网格列数不至于停在默认值
      try {
        const disp = display.getDefaultDisplaySync();
        this.applyWindowWidth(disp.width, disp.height);
      } catch (e2) {
        Logger.w('屏幕宽度也读不到，保持默认布局');
      }
    }
  }

  /**
   * 按窗口尺寸重算断点、内容宽度与网格列数。
   *
   * 判断维度是「窗口形态」而不是设备类型：折叠屏展开、横屏手机、平板
   * 本质都是宽而矮的窗口，用宽高比一把尺子就能统一。
   * 竖屏手机比例约 0.46，折叠屏展开约 0.9，平板横屏 1.4 以上，
   * 所以 0.8 是「竖长手机」与「宽屏」的分界。
   *
   * 不能用 display.isFoldable()：模拟器在直板机上也会把它报成 true。
   */
  private applyWindowWidth(pxWidth: number, pxHeight: number): void {
    const vw = px2vp(pxWidth);
    const vh = px2vp(pxHeight);
    this.windowW = vw;

    const ratio = vh > 0 ? vw / vh : 0.5;
    // 宽而矮的窗口才把页签挪到左侧，竖屏手机保持底部页签
    this.isWide = vw >= 600 && ratio >= 0.8;

    // 左右各 20 内边距；用侧边栏时再让出导航栏宽度
    this.contentWidth = vw - 40 - (this.isWide ? this.railWidth : 0);

    // 列数只看内容区实际宽度：窄了铺 3 列，宽了 4 列，特别宽 5 列
    this.gridCols = this.contentWidth >= 900 ? 5
      : this.contentWidth >= 640 ? 4 : 3;

    // 宽屏播放页单独算。左屏控件多（5 个播放键 + 5 个功能键），
    // 所以两栏按 55:45 分而不是对半，窄窗口下才不会挤成一团。
    const usable = vw - 48;
    const leftW = usable * 0.55;
    this.wideColW = Math.min(340, Math.max(240, leftW - 64));
    // 封面按窗口高度的比例走，而不是减一堆固定像素：
    // 阔折叠 665 高和大折叠 773 高都能自然缩放。
    // 取 0.40 而不是更大：矮屏（665）要留出一点弹性留白，
    // 高屏（773）的封面会被列宽 299 卡住，不会无限变大。
    this.wideCover = Math.min(this.wideColW, vh * 0.40);

    // 竖屏播放页同样用高度比例：普通手机取宽度上限，
    // 阔折叠外屏这种矮宽窗口则由高度决定，避免把功能行顶出屏幕。
    this.narrowCover = Math.max(150, Math.min(vw - 40, vh * 0.44));

    // 宽屏歌词已经常驻右屏了，从窄屏切过来时把全屏歌词浮层收掉
    if (this.isWide) {
      this.showLyrics = false;
    }

    Logger.i(`窗口 ${vw.toFixed(0)}x${vh.toFixed(0)}vp 比例=${ratio.toFixed(2)} `
      + `类型=${deviceInfo.deviceType} 侧栏=${this.isWide} 内容宽=${this.contentWidth.toFixed(0)} `
      + `列=${this.gridCols} 播放页列=${this.wideColW.toFixed(0)} 封面=${this.wideCover.toFixed(0)}`);
  }

  build() {
    Stack() {
      this.backdrop()

      Row() {
        // 宽屏把底部页签挪到左侧，纵向空间全部留给内容
        if (this.isWide) {
          this.railBar()
        }

        Column() {
          this.header()
          this.statusLine()

          Column() {
            if (this.online.detailOpen) {
              this.onlineDetail()
            } else if (this.tab === 0) {
              this.homeTab()
            } else if (this.tab === 1) {
              this.exploreTab()
            } else if (this.tab === 2) {
              this.libraryTab()
            } else {
              this.settingsTab()
            }
          }
          .width('100%')
          .layoutWeight(1)
          .opacity(this.tabFade)
          .translate({ x: this.tabShiftX })
        }
        .layoutWeight(1)
        .height('100%')
        .padding({
          left: 20,
          right: 20,
          top: this.topInset + 12,
          bottom: 0
        })
      }
      .width('100%')
      .height('100%')

      // 底部悬浮层：迷你播放器 + 页签栏。整层不拦截空白处的点击
      Column() {
        Blank()
        Column({ space: 10 }) {
          if (this.player.currentPath.length > 0) {
            this.miniPlayer()
          }
          // 宽屏用左侧导航栏，底部只留迷你播放器
          if (!this.isWide) {
            this.tabBar()
          }
        }
        .width('100%')
        .padding({
          left: this.isWide ? this.railWidth + 14 : 14,
          right: 14,
          bottom: this.bottomInset + 8
        })
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)

      if (this.showPlayer) {
        // 宽屏走左右分栏，歌词常驻右侧
        if (this.isWide) {
          this.widePlayerOverlay()
        } else {
          this.playerOverlay()
        }
      }

      if (this.showLyrics) {
        this.lyricsOverlay()
      }

      // 队列要压在歌词页上面：歌词页底部也有队列入口
      if (this.showQueue) {
        this.queueOverlay()
      }

      if (this.artistSt.open) {
        this.artistOverlay()
      }

      if (this.mvSt.open) {
        this.mvOverlay()
      }

      // 评论可以叠在艺人页和 MV 上
      if (this.commentSt.open) {
        this.commentOverlay()
      }

      if (this.showLogin) {
        this.loginOverlay()
      }

      // 长按菜单能盖住上面所有页面
      if (this.actionOpen) {
        this.songActionOverlay()
      }

      // 选歌单压在菜单之上；菜单里点「加入歌单」即使没关菜单也不会被遮
      if (this.pickerPath.length > 0) {
        this.pickerOverlay()
      }

      // 新建歌单压在选歌单之上：从选歌单里点「新建」要能盖住它
      if (this.showCreate) {
        this.createPlaylistDialog()
      }

      // 隐藏的网页：只为拿到网易云的风控指纹（ydDeviceToken）和 sDeviceId。
      // 安卓版 NeteaseYdDeviceTokenProvider 也是开一个 WebView 执行 createNEFingerprint，
      // 没有这个令牌，扫码确认后服务端不会把状态推到 803。
      if (this.showLogin && !this.auth.loggedIn) {
        Web({ src: 'https://music.163.com/', controller: this.fpCtl })
          .width('100%')
          .height('100%')
          .opacity(0)
          .hitTestBehavior(HitTestMode.None)
          // 与安卓版 NeteaseYdDeviceTokenProvider 完全相同的桌面 UA，
          // 指纹脚本只对桌面浏览器下发
          .userAgent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
            + '(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0')
          .onPageEnd(() => {
            this.probeFingerprint(0);
          })
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * 背景层：底色渐变 + 两团主题色光斑。
   * 光斑是静态的（只渲染一次），但大半径 blur 在低端机仍有成本，
   * 所以跟着「毛玻璃效果」开关一起关。
   */
  @Builder
  backdrop() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 160,
          colors: [['#151312', 0.0], ['#221D1B', 0.55], ['#191513', 1.0]]
        })

      if (this.st.blur) {
        // 用径向渐变做光晕：比 blur(Circle) 稳，不会被裁成方块，
        // 低端机上也是单次绘制，不产生逐帧开销。
        Column()
          .width('100%')
          .height('100%')
          .radialGradient({
            center: ['2%', '0%'],
            radius: 760,
            colors: [
              [settings.accentSoft(0.26), 0.0],
              [settings.accentSoft(0.12), 0.42],
              [settings.accentSoft(0.0), 1.0]
            ]
          })
        Column()
          .width('100%')
          .height('100%')
          .radialGradient({
            center: ['96%', '94%'],
            radius: 660,
            colors: [
              [settings.accentSoft(0.12), 0.0],
              [settings.accentSoft(0.0), 1.0]
            ]
          })
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  header() {
    Row() {
      Column({ space: 4 }) {
        Text(this.tabTitle())
          .fontSize(this.tab === 0 ? 26 : 24)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT_MAIN)
          .letterSpacing(this.tab === 0 ? 1.5 : 0.4)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.tabSubtitle())
          .fontSize(11)
          .fontColor(TEXT_SUB)
          .letterSpacing(0.4)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 首页与探索给一个账号入口：已登录显示头像，未登录显示「登录」
      if (this.tab === 0 || this.tab === 1) {
        Row() {
          if (this.auth.loggedIn && this.auth.avatarUrl.length > 0) {
            Image(this.auth.avatarUrl)
              .width(32)
              .height(32)
              .borderRadius(16)
              .objectFit(ImageFit.Cover)
              .draggable(false)
          } else {
            Text('登录')
              .fontSize(10)
              .fontColor(TEXT_SUB)
              .height(28)
              .padding({ left: 12, right: 12 })
              .borderRadius(14)
              .textAlign(TextAlign.Center)
              .backgroundColor('#14FFFFFF')
          }
        }
        .onClick(() => {
          if (this.auth.loggedIn) {
            this.settingsPage = 'online';
            this.switchTab(3);
          } else {
            this.openLogin();
          }
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 12 })
  }

  // ─────────────────── 四个页签 ───────────────────

  @Builder
  homeTab() {
    Column() {
      this.onlineHome()
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  exploreTab() {
    Column() {
      this.onlineSearchRow()
      if (this.online.hasSearched) {
        this.onlineTabRow()
        this.onlineResultArea()
      } else {
        this.exploreFeed()
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /**
   * 探索页信息流：一行关键词 + 为你推荐歌单。
   * 用 List 承载（只布局可视区域），快到底前两行就预取下一页，
   * 服务端按分类轮转取数，所以可以一直往下滑。
   */
  @Builder
  exploreFeed() {
    Column() {
      this.exploreWords()

      if (this.online.explorePlaylists.length === 0) {
        if (this.online.exploreLoading) {
          Column({ space: 10 }) {
            LoadingProgress()
              .width(22)
              .height(22)
              .color(settings.accent())
            Text('正在加载推荐…')
              .fontSize(11)
              .fontColor(TEXT_SUB)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Column({ space: 10 }) {
            Text('没有拉到推荐歌单')
              .fontSize(12)
              .fontColor(TEXT_SUB)
            Text('重试')
              .fontSize(11)
              .fontColor('#1E1A18')
              .height(32)
              .padding({ left: 18, right: 18 })
              .borderRadius(16)
              .textAlign(TextAlign.Center)
              .backgroundColor(settings.accent())
              .onClick(() => {
                netease.loadExplore(true);
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        }
      } else {
        List({ space: 14 }) {
          ListItem() {
            this.homeSectionHeader('★', '为你推荐')
          }

          ForEach(this.playlistChunks(this.online.explorePlaylists),
            (row: NeteasePlaylist[], ri: number) => {
              ListItem() {
                Row({ space: 10 }) {
                  ForEach(row, (p: NeteasePlaylist) => {
                    this.homePlaylistCell(p)
                  }, (p: NeteasePlaylist) => `ex_${ri}_${p.id}`)
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
              }
            }, (row: NeteasePlaylist[], ri: number) => `exrow_${ri}`)

          if (this.online.exploreLoading) {
            ListItem() {
              Row({ space: 8 }) {
                LoadingProgress()
                  .width(16)
                  .height(16)
                  .color(settings.accent())
                Text('正在加载更多…')
                  .fontSize(10)
                  .fontColor(TEXT_SUB)
              }
              .width('100%')
              .padding({ top: 14, bottom: 14 })
              .justifyContent(FlexAlign.Center)
            }
          }
        }
        .width('100%')
        .layoutWeight(1)
        .contentEndOffset(this.chromeInset())
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(4)
        .onScrollIndex((first: number, last: number) => {
          // 离底还有六行（约两屏）就预取：快速甩动也不会撞到列表尽头
          if (last >= this.exploreRowCount() - 6) {
            netease.loadExplore(false);
          }
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 探索页数据行数（每行三个），预取判定用 */
  private exploreRowCount(): number {
    return Math.ceil(this.online.explorePlaylists.length / 3);
  }

  /** 关键词横排，点了直接搜 */
  @Builder
  exploreWords() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(EXPLORE_WORDS, (word: string) => {
          Text(word)
            .fontSize(11)
            .fontColor(TEXT_MAIN)
            .height(30)
            .padding({ left: 12, right: 12 })
            .borderRadius(15)
            .textAlign(TextAlign.Center)
            .backgroundColor('#10FFFFFF')
            .onClick(() => {
              this.online.keyword = word;
              netease.search(word);
            })
        }, (word: string) => `ew_${word}`)
      }
      .padding({ top: 2, bottom: 2 })
    }
    .width('100%')
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .margin({ bottom: 2 })
  }

  @Builder
  libraryTab() {
    Column() {
      this.searchRow()
      this.libQuickRow()
      this.sectionChips()

      if (this.libSection === 0) {
        if (this.viewMode === 0) {
          if (this.lib.displaySongs.length > 0) {
            this.songList(this.lib.displaySongs)
          } else if (this.lib.songs.length > 0) {
            this.noResultState()
          } else {
            this.emptyState()
          }
        } else if (this.viewMode === 3) {
          if (this.playlistId.length === 0) {
            this.playlistList()
          } else {
            this.playlistDetail()
          }
        } else if (this.viewMode === 4) {
          this.recentView()
        } else if (this.groupKey.length === 0) {
          this.groupList()
        } else {
          this.groupSongsView()
        }
      } else if (this.libSection === 1) {
        if (this.favTab === 0) {
          this.favoriteView()
        } else if (this.favGroupKey.length === 0) {
          this.favGroupList()
        } else {
          Column() {
            Row() {
              Text(`‹ ${this.favTab === 1 ? '全部专辑' : '全部艺术家'}`)
                .fontSize(11)
                .fontColor(settings.accent())
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(12)
                .backgroundColor(settings.accentSoft(0.10))
                .onClick(() => {
                  this.favGroupKey = '';
                })
              Blank()
              Text('播放全部')
                .fontSize(11)
                .fontColor('#1E1A18')
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(12)
                .backgroundColor(settings.accent())
                .onClick(() => {
                  const songs = this.favGroupSongs(this.favTab === 1, this.favGroupKey);
                  if (songs.length > 0) {
                    playback.setQueue(songs);
                    playback.playIndex(0);
                  }
                })
            }
            .width('100%')
            .margin({ top: 8, bottom: 4 })

            this.songList(this.favGroupSongs(this.favTab === 1, this.favGroupKey), 2)
          }
          .width('100%')
          .layoutWeight(1)
        }
      } else {
        this.downloadView()
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  settingsTab() {
    Column() {
      if (this.settingsPage.length > 0) {
        Row() {
          Text('‹ 返回')
            .fontSize(11)
            .fontColor(settings.accent())
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(12)
            .backgroundColor(settings.accentSoft(0.10))
            .onClick(() => {
              this.leaveSettingsPage('');
            })
          Blank()
        }
        .width('100%')
        .margin({ bottom: 4 })
      }

      Scroll() {
        if (this.settingsPage.length === 0) {
          this.settingsHome()
        } else if (this.settingsPage === 'appearance') {
          this.settingsAppearancePage()
        } else if (this.settingsPage === 'playback') {
          this.settingsPlaybackPage()
        } else if (this.settingsPage === 'lyrics') {
          this.settingsLyricsPage()
        } else if (this.settingsPage === 'library') {
          this.settingsLibraryPage()
        } else if (this.settingsPage === 'online') {
          this.settingsOnlinePage()
        } else if (this.settingsPage === 'storage') {
          this.settingsStoragePage()
        } else if (this.settingsPage === 'stats') {
          this.settingsStatsPage()
        } else if (this.settingsPage === 'backup') {
          this.settingsBackupPage()
        } else {
          this.settingsAboutPage()
        }
      }
      .width('100%')
      .layoutWeight(1)
      .contentEndOffset(this.chromeInset())
      .scrollBar(BarState.Off)
      .margin({ top: 4 })
      .opacity(this.settingsFade)
      .translate({ x: this.settingsShiftX })
    }
    .width('100%')
    .layoutWeight(1)
  }

  // ─────────────────── 设置：首页 ───────────────────

  @Builder
  settingsHome() {
    Column({ space: 2 }) {
      this.settingsAccountCard()

      this.settingsSectionIntro('个性化', '主题、播放与歌词都按你的习惯来')
      Column() {
        this.settingsNavRow('色', '外观与主题', this.appearanceSummary(), 'appearance')
        this.settingsDivider()
        this.settingsNavRow('播', '播放', this.playbackSummary(), 'playback')
        this.settingsDivider()
        this.settingsNavRow('词', '歌词', this.lyricsSummary(), 'lyrics')
      }
      .width('100%')
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
      .clip(true)

      this.settingsSectionIntro('内容与账号', '曲库、离线下载和网易云')
      Column() {
        this.settingsNavRow('库', '曲库与下载', this.librarySummary(), 'library')
        this.settingsDivider()
        this.settingsNavRow('云', '网易云', this.onlineSummary(), 'online')
      }
      .width('100%')
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
      .clip(true)

      this.settingsSectionIntro('数据', '听歌统计、存储占用与备份')
      Column() {
        this.settingsNavRow('统', '听歌统计', '播放次数、收听时长与最常听', 'stats')
        this.settingsDivider()
        this.settingsNavRow('存', '存储管理', this.storageSummary(), 'storage')
        this.settingsDivider()
        this.settingsNavRow('备', '备份与恢复', '设置、歌单、收藏导出成 JSON', 'backup')
      }
      .width('100%')
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
      .clip(true)

      this.settingsSectionIntro('关于', '版本与本地统计')
      Column() {
        this.settingsNavRow('i', '关于 MEMI 輕音', `0.1.0 · 曲库 ${this.lib.songs.length} 首`, 'about')
      }
      .width('100%')
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
      .clip(true)

      Text('MEMI 輕音 · 本地优先的音乐播放器')
        .fontSize(9)
        .fontColor('#4A403A')
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 18, bottom: 12 })
    }
    .width('100%')
  }

  @Builder
  settingsAccountCard() {
    Row({ space: 12 }) {
      if (this.auth.loggedIn && this.auth.avatarUrl.length > 0) {
        Image(this.auth.avatarUrl)
          .width(42)
          .height(42)
          .borderRadius(21)
          .objectFit(ImageFit.Cover)
          .draggable(false)
      } else {
        Text('♪')
          .fontSize(16)
          .fontColor(TEXT_SUB)
          .width(42)
          .height(42)
          .borderRadius(21)
          .textAlign(TextAlign.Center)
          .backgroundColor('#14FFFFFF')
      }
      Column({ space: 3 }) {
        Text(this.auth.loggedIn ? this.auth.nickname : '未登录')
          .fontSize(14)
          .fontColor(TEXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.auth.loggedIn ? this.auth.vipLabel() : '登录后可播会员曲目、解锁更高音质')
          .fontSize(10)
          .fontColor('#7A6A62')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(this.auth.loggedIn ? '管理' : '登录')
        .fontSize(10)
        .fontColor('#241C18')
        .height(26)
        .padding({ left: 14, right: 14 })
        .borderRadius(13)
        .textAlign(TextAlign.Center)
        .backgroundColor(settings.accent())
    }
    .width('100%')
    .padding({ top: 12, bottom: 12, left: 14, right: 14 })
    .margin({ top: 2, bottom: 2 })
    .borderRadius(20)
    .backgroundColor('#0DFFFFFF')
    .borderWidth(0.5)
    .borderColor('#18FFFFFF')
    .onClick(() => {
      this.settingsPage = 'online';
    })
  }

  @Builder
  settingsSectionIntro(title: string, desc: string) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(settings.accent())
      Text(desc)
        .fontSize(10)
        .fontColor('#8C7C74')
    }
    .width('100%')
    .padding({ left: 4, top: 16, bottom: 7 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  settingsNavRow(glyph: string, title: string, subtitle: string, page: string) {
    Row({ space: 12 }) {
      Text(glyph)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(settings.accent())
        .width(30)
        .height(30)
        .borderRadius(9)
        .textAlign(TextAlign.Center)
        .backgroundColor(settings.accentSoft(0.12))
      Column({ space: 2 }) {
        Text(title)
          .fontSize(14)
          .fontColor(TEXT_MAIN)
          .width('100%')
        Text(subtitle)
          .fontSize(10)
          .fontColor('#7A6A62')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(18)
        .fontColor('#5A4A42')
    }
    .width('100%')
    .height(58)
    .padding({ left: 14, right: 14 })
    .onClick(() => {
      this.enterSettingsPage(page);
    })
  }

  /** 进设置子页：从右侧推入 */
  private enterSettingsPage(page: string): void {
    this.settingsShiftX = 22;
    this.settingsFade = 0;
    this.settingsPage = page;
    if (page === 'storage') {
      this.measureStorage();
    } else if (page === 'lyrics') {
      this.syncLyricFlag();
    } else if (page === 'stats') {
      stats.refresh();
    }
    animateTo({ duration: settings.motionMs(260), curve: Curve.FastOutSlowIn }, () => {
      this.settingsFade = 1;
      this.settingsShiftX = 0;
    });
  }

  /** 退出设置子页：从左侧回来 */
  private leaveSettingsPage(page: string): void {
    this.settingsShiftX = -18;
    this.settingsFade = 0;
    this.settingsPage = page;
    animateTo({ duration: settings.motionMs(240), curve: Curve.FastOutSlowIn }, () => {
      this.settingsFade = 1;
      this.settingsShiftX = 0;
    });
  }

  @Builder
  settingsDivider() {
    Divider()
      .strokeWidth(0.6)
      .color('#12FFFFFF')
      .margin({ left: 56, right: 14 })
  }

  /** 纯文字信息行用的分隔线：没有图标，就不留 56 的缩进 */
  @Builder
  settingsDividerPlain() {
    Divider()
      .strokeWidth(0.6)
      .color('#12FFFFFF')
      .margin({ left: 14, right: 14 })
  }

  @Builder
  settingsToggleRow(title: string, desc: string, isOn: boolean, onChange: (v: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(14)
          .fontColor(TEXT_MAIN)
          .width('100%')
        Text(desc)
          .fontSize(10)
          .fontColor('#7A6A62')
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(settings.accent())
        .switchPointColor('#FFF6F0')
        .onChange((on: boolean) => {
          onChange(on);
        })
    }
    .width('100%')
    .padding({ top: 12, bottom: 12, left: 14, right: 14 })
  }

  @Builder
  settingsActionRow(title: string, desc: string, danger: boolean, onTap: () => void) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(14)
          .fontColor(danger ? '#FF8A8A' : TEXT_MAIN)
          .width('100%')
        Text(desc)
          .fontSize(10)
          .fontColor('#7A6A62')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(18)
        .fontColor('#5A4A42')
    }
    .width('100%')
    .padding({ top: 12, bottom: 12, left: 14, right: 14 })
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  settingsInfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(TEXT_SUB)
      Blank()
      Text(value)
        .fontSize(12)
        .fontColor(TEXT_MAIN)
    }
    .width('100%')
    .padding({ top: 7, bottom: 7 })
  }

  // ─────────────────── 设置：子页 ───────────────────

  @Builder
  settingsAppearancePage() {
    Column({ space: 2 }) {
      this.settingsSectionIntro('主题色', '换一套主色，列表、按钮与歌词高亮都会跟着变')
      Row({ space: 12 }) {
        ForEach(ACCENTS, (item: AccentPreset, i: number) => {
          Column({ space: 6 }) {
            Stack() {
              Column()
                .width(44)
                .height(44)
                .borderRadius(22)
                .borderWidth(this.st.accentIndex === i ? 1.5 : 0)
                .borderColor(item.hex)
              Circle()
                .width(this.st.accentIndex === i ? 34 : 32)
                .height(this.st.accentIndex === i ? 34 : 32)
                .fill(item.hex)
                .opacity(this.st.accentIndex === i ? 1 : 0.55)
            }
            .width(48)
            .height(48)

            Text(item.name)
              .fontSize(9)
              .fontColor(this.st.accentIndex === i ? TEXT_MAIN : '#5A4A42')
          }
          .onClick(() => {
            settings.setAccentIndex(i);
          })
        }, (item: AccentPreset) => item.hex)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .padding({ top: 4, bottom: 14, left: 6, right: 6 })

      this.settingsSectionIntro('显示', '低端机可以关掉毛玻璃与缩略图')
      Column() {
        this.settingsToggleRow('毛玻璃效果', '关闭后更省电，低端机更流畅', this.st.blur, (on: boolean) => {
          settings.setBlur(on);
        })
        this.settingsDivider()
        this.chromeGlassSlider()
        this.settingsDivider()
        this.settingsToggleRow('列表缩略图', '从音频里解出封面，关闭可省内存', this.st.showThumbs, (on: boolean) => {
          settings.setShowThumbs(on);
        })
      }
      .width('100%')
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
      .clip(true)

      this.settingsSectionIntro('界面与动效', '缩放影响列表行高与歌词基准字号，不会改左右边距')
      Column() {
        Row({ space: 6 }) {
          Text('界面缩放')
            .fontSize(14)
            .fontColor(TEXT_MAIN)
            .layoutWeight(1)
          this.uiScaleChip('紧凑', 0.9)
          this.uiScaleChip('标准', 1.0)
          this.uiScaleChip('宽松', 1.1)
        }
        .width('100%')
        .padding({ top: 12, bottom: 12, left: 14, right: 14 })

        this.settingsDivider()

        Row({ space: 6 }) {
          Text('动效')
            .fontSize(14)
            .fontColor(TEXT_MAIN)
            .layoutWeight(1)
          this.motionChip('完整', 0)
          this.motionChip('精简', 1)
          this.motionChip('关闭', 2)
        }
        .width('100%')
        .padding({ top: 12, bottom: 12, left: 14, right: 14 })

        this.settingsDivider()

        Text('关闭动效后，转场与唱片旋转会立刻完成；省电模式下手感更接近本地播放器')
          .fontSize(9)
          .fontColor('#5A4A42')
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 12 })
      }
      .width('100%')
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
      .clip(true)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .padding({ bottom: 16 })
  }

  @Builder
  settingsPlaybackPage() {
    Column({ space: 2 }) {
      this.settingsSectionIntro('播放行为', '恢复上次进度与启动方式')
      Column() {
        this.settingsToggleRow('记住播放进度', '下次打开从上次听到的位置继续', this.st.rememberProgress,
          (on: boolean) => {
            settings.setRememberProgress(on);
          })
        this.settingsDivider()
        this.settingsToggleRow('启动自动续播', '进入 App 直接接着上次听，需要同时开启「记住播放进度」',
          this.st.autoResume, (on: boolean) => {
            settings.setAutoResume(on);
          })
      }
      .width('100%')
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
      .clip(true)

      this.settingsSectionIntro('默认倍速', '只影响启动时的初始值，播放页随时可改')
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          ForEach(SPEED_OPTIONS, (v: number) => {
            this.speedChip(v)
          }, (v: number) => `${v}`)
        }
        .width('100%')

        Text('启动时生效')
          .fontSize(9)
          .fontColor('#5A4A42')
          .width('100%')
      }
      .width('100%')
      .padding(14)
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .padding({ bottom: 16 })
  }

  @Builder
  settingsLyricsPage() {
    Column({ space: 2 }) {
      this.settingsSectionIntro('歌词排版', '正文字号、翻译字号与译文开关')
      Column() {
        this.lyricBodySlider()

        this.settingsDivider()
        this.lyricTransSlider()

        this.settingsDivider()
        this.settingsToggleRow('显示译文', '歌词里带翻译时显示第二行', this.st.showTranslation,
          (on: boolean) => {
            settings.setShowTranslation(on);
          })
      }
      .width('100%')
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
      .clip(true)

      this.settingsSectionIntro('外部歌词', '同名 .lrc / .yrc / .ttml 与手动导入')
      Column() {
        this.settingsToggleRow('外部歌词优先', '关闭后先读音频内嵌标签，再退回同名歌词文件',
          this.st.externalLyricFirst, (on: boolean) => {
            settings.setExternalLyricFirst(on);
          })
        this.settingsDivider()
        this.settingsActionRow('为当前歌曲导入歌词', this.lyricImportHint(), false, () => {
          this.pickLyricFile();
        })
        if (this.lyricImported) {
          this.settingsDivider()
          this.settingsActionRow('移除已导入的歌词', '删掉后回到外挂文件或音频标签', true, () => {
            this.removeLyricFile();
          })
        }
      }
      .width('100%')
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
      .clip(true)

      Text('导入的歌词存在应用沙箱里，卸载应用会一起清掉')
        .fontSize(9)
        .fontColor('#5A4A42')
        .width('100%')
        .padding({ left: 4, top: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .padding({ bottom: 16 })
  }

  @Builder
  sortModeChip(label: string, mode: number) {
    Text(label)
      .fontSize(11)
      .fontColor(this.st.sortMode === mode ? '#241C18' : TEXT_SUB)
      .height(30)
      .layoutWeight(1)
      .borderRadius(15)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.st.sortMode === mode ? settings.accent() : '#14FFFFFF')
      .onClick(() => {
        settings.setSortMode(mode);
      })
  }

  @Builder
  settingsLibraryPage() {
    Column({ space: 2 }) {
      this.settingsSectionIntro('曲库', '排序方式与导入过滤')
      Column() {
        Row({ space: 6 }) {
          Text('默认排序')
            .fontSize(14)
            .fontColor(TEXT_MAIN)
            .layoutWeight(1)
          this.sortModeChip('标题', 0)
          this.sortModeChip('艺术家', 1)
          this.sortModeChip('时长', 2)
        }
        .width('100%')
        .padding({ top: 12, bottom: 12, left: 14, right: 14 })

        this.settingsDivider()
        this.settingsToggleRow('忽略短音频', '导入时跳过短于 30 秒的文件（提示音、铃声）',
          this.st.skipShort, (on: boolean) => {
            settings.setSkipShort(on);
          })
      }
      .width('100%')
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
      .clip(true)

      this.settingsSectionIntro('存储与下载', '离线文件保存在应用沙箱')
      Column() {
        Row({ space: 12 }) {
          Text('下')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(settings.accent())
            .width(30)
            .height(30)
            .borderRadius(9)
            .textAlign(TextAlign.Center)
            .backgroundColor(settings.accentSoft(0.12))
          Column({ space: 2 }) {
            Text('下载管理')
              .fontSize(14)
              .fontColor(TEXT_MAIN)
              .width('100%')
            Text(`${this.dl.doneSongs.length} 首 · ${formatBytes(this.dl.totalBytes)}`)
              .fontSize(10)
              .fontColor('#7A6A62')
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Text('›')
            .fontSize(18)
            .fontColor('#5A4A42')
        }
        .width('100%')
        .height(58)
        .padding({ left: 14, right: 14 })
        .onClick(() => {
          this.settingsPage = '';
          this.tab = 2;
          this.libSection = 2;
          this.dlTab = 0;
          this.onModeChanged(8);
        })
      }
      .width('100%')
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
      .clip(true)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .padding({ bottom: 16 })
  }

  @Builder
  settingsOnlinePage() {
    Column({ space: 2 }) {
      this.settingsSectionIntro('账号', '登录后可播放会员曲目、解锁更高音质')
      Row({ space: 12 }) {
        if (this.auth.loggedIn && this.auth.avatarUrl.length > 0) {
          Image(this.auth.avatarUrl)
            .width(42)
            .height(42)
            .borderRadius(21)
            .objectFit(ImageFit.Cover)
            .draggable(false)
        } else {
          Image($r('app.media.ic_note'))
            .width(18)
            .height(18)
            .fillColor(TEXT_SUB)
            .margin(12)
        }
        Column({ space: 3 }) {
          Text(this.auth.loggedIn ? this.auth.nickname : '未登录')
            .fontSize(14)
            .fontColor(TEXT_MAIN)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.auth.loggedIn ? this.auth.vipLabel() : '登录后可播会员曲目、解锁更高音质')
            .fontSize(10)
            .fontColor('#7A6A62')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.auth.loggedIn ? '退出' : '登录')
          .fontSize(10)
          .fontColor(this.auth.loggedIn ? '#FF6B6B' : '#241C18')
          .height(28)
          .padding({ left: 16, right: 16 })
          .borderRadius(14)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.auth.loggedIn ? '#1AFF6B6B' : settings.accent())
          .onClick(() => {
            if (this.auth.loggedIn) {
              this.confirmLogout();
            } else {
              this.openLogin();
            }
          })
      }
      .width('100%')
      .padding({ top: 12, bottom: 12, left: 14, right: 14 })
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')

      this.settingsSectionIntro('音质', '实际码率由账号权限决定')
      Column({ space: 8 }) {
        Row() {
          Text('在线音质')
            .fontSize(14)
            .fontColor(TEXT_MAIN)
          Blank()
          Text(settings.onlineQualityLabel())
            .fontSize(11)
            .fontColor(settings.accent())
        }
        .width('100%')

        Row({ space: 6 }) {
          this.qualityChip('标准', 0)
          this.qualityChip('高', 1)
          this.qualityChip('无损', 2)
          this.qualityChip('Hi-Res', 3)
        }
        .width('100%')

        Text('非会员选择无损会自动降档到 320k')
          .fontSize(9)
          .fontColor('#5A4A42')
          .width('100%')
      }
      .width('100%')
      .padding({ top: 12, bottom: 12, left: 14, right: 14 })
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .padding({ bottom: 16 })
  }

  @Builder
  settingsStatsPage() {
    Scroll() {
      Column() {
        this.statsContent()
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .contentEndOffset(this.chromeInset())
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  settingsAboutPage() {
    Column({ space: 2 }) {
      this.settingsSectionIntro('关于', 'MEMI 輕音 · 本地优先的音乐播放器')
      Column() {
        this.settingsInfoRow('版本', '0.1.0 · 鸿蒙原生')
        this.settingsDividerPlain()
        this.settingsInfoRow('曲库', `${this.lib.songs.length} 首 · ${this.totalDurationText()}`)
        this.settingsDividerPlain()
        this.settingsInfoRow('歌单 / 收藏', `${this.playlistsState.lists.length} 个 / ${this.favoriteSongs.length} 首`)
        this.settingsDividerPlain()
        this.settingsInfoRow('下载', `${this.dl.doneSongs.length} 首 · ${formatBytes(this.dl.totalBytes)}`)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
      .clip(true)

      Text('内容来自网易云音乐公开接口，仅用于个人试听。')
        .fontSize(9)
        .fontColor('#4A403A')
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 18, bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .padding({ bottom: 16 })
  }

  @Builder
  settingsStoragePage() {
    Column({ space: 2 }) {
      this.settingsSectionIntro('占用', '只统计应用沙箱，用户目录里的音频不计入')
      Column() {
        this.settingsInfoRow('下载的歌曲', formatBytes(this.storageState.downloads))
        this.settingsDividerPlain()
        this.settingsInfoRow('导入的歌词', formatBytes(this.storageState.lyrics))
        this.settingsDividerPlain()
        this.settingsInfoRow('曲库数据库', formatBytes(this.storageState.database))
        this.settingsDividerPlain()
        this.settingsInfoRow('缓存', formatBytes(this.storageState.cache))
        this.settingsDividerPlain()
        this.settingsInfoRow('合计', this.storageState.scanning ? '统计中…' : formatBytes(this.storageState.total()))
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
      .clip(true)

      this.settingsSectionIntro('操作', '缓存可以随时清，歌曲和歌词不会动')
      Column() {
        this.settingsActionRow('重新统计', this.storageState.scanning ? '正在统计…' : '点一下刷新上面的数字',
          false, () => {
            this.measureStorage();
          })
        this.settingsDividerPlain()
        this.settingsActionRow('清理缓存', `当前 ${formatBytes(this.storageState.cache)}，只删 cacheDir`,
          false, () => {
            this.confirmClearCache();
          })
      }
      .width('100%')
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
      .clip(true)

      Text('缓存里主要是封面解码的中间文件，清掉后下次加载会重新生成，不影响播放。')
        .fontSize(9)
        .fontColor('#4A403A')
        .width('100%')
        .padding({ left: 4, top: 10 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .padding({ bottom: 16 })
  }

  @Builder
  settingsBackupPage() {
    Column({ space: 2 }) {
      this.settingsSectionIntro('导出', '设置、自建歌单、收藏写成一份 JSON')
      Column() {
        this.settingsActionRow('导出备份文件',
          this.backupBusy ? '正在处理…' : '自己选保存位置，文件名带日期', false, () => {
            this.exportBackup();
          })
      }
      .width('100%')
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
      .clip(true)

      this.settingsSectionIntro('恢复', '同 id 的歌单会被覆盖，收藏按路径累加')
      Column() {
        this.settingsActionRow('从备份文件恢复',
          this.backupBusy ? '正在处理…' : '选择之前导出的 .json', false, () => {
            this.confirmImportBackup();
          })
      }
      .width('100%')
      .borderRadius(20)
      .backgroundColor('#0DFFFFFF')
      .borderWidth(0.5)
      .borderColor('#18FFFFFF')
      .clip(true)

      if (this.backupMsg.length > 0) {
        Text(this.backupMsg)
          .fontSize(10)
          .fontColor(settings.accent())
          .width('100%')
          .padding({ left: 4, top: 12 })
      }

      Text('备份不含音频文件。换设备后先把曲库导入一遍，歌单里的路径会自动接上。')
        .fontSize(9)
        .fontColor('#4A403A')
        .width('100%')
        .padding({ left: 4, top: 12 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .padding({ bottom: 16 })
  }

  // ─────────────────── 页签 / 底部悬浮层 ───────────────────

  /** 切页签：内容淡入 + 按方向轻推，对应安卓的 tab 场景切换 */
  private switchTab(index: number): void {
    if (index === this.tab) {
      return;
    }
    this.tabShiftX = index > this.tab ? 26 : -26;
    this.tabFade = 0;
    this.tab = index;
    animateTo({ duration: settings.motionMs(260), curve: Curve.FastOutSlowIn }, () => {
      this.tabFade = 1;
      this.tabShiftX = 0;
    });
  }

  private tabTitle(): string {
    if (this.tab === 3) {
      return this.settingsTitle();
    }
    if (this.tab === 1) {
      return '探索';
    }
    if (this.tab === 2) {
      return '媒体库';
    }
    return 'MEMI 輕音';
  }

  private tabSubtitle(): string {
    if (this.tab === 0) {
      return this.auth.loggedIn ? '网易云每日推荐' : '未登录 · 点右上角登录';
    }
    if (this.tab === 1) {
      return '搜索网易云音乐';
    }
    if (this.tab === 2) {
      return `本地 ${this.lib.songs.length} 首 · 已下载 ${this.dl.doneSongs.length} 首`;
    }
    return this.settingsPage.length === 0 ? '外观、播放与数据' : ' ';
  }

  /**
   * 底部悬浮层占掉的高度。
   * 内容区本身不留白（信息流要从悬浮层下面穿过去），
   * 只给每个可滚动列表加 contentEndOffset，保证最后一行能滚到悬浮层上面。
   */
  private chromeInset(): number {
    const mini = this.player.currentPath.length > 0 ? 72 : 0;
    return this.bottomInset + 8 + mini + 64 + 12;
  }

  /** 迷你播放器的副标题：歌手优先，没歌手就退回进度 */
  private miniSubtitle(): string {
    if (this.player.artist.length > 0) {
      return this.player.artist;
    }
    if (this.player.durationMs > 0) {
      return `${formatTime(this.player.positionMs)} / ${formatTime(this.player.durationMs)}`;
    }
    return ' ';
  }

  private settingsTitle(): string {
    if (this.settingsPage === 'appearance') {
      return '外观与主题';
    }
    if (this.settingsPage === 'playback') {
      return '播放';
    }
    if (this.settingsPage === 'lyrics') {
      return '歌词';
    }
    if (this.settingsPage === 'library') {
      return '曲库与下载';
    }
    if (this.settingsPage === 'online') {
      return '网易云';
    }
    if (this.settingsPage === 'storage') {
      return '存储管理';
    }
    if (this.settingsPage === 'stats') {
      return '听歌统计';
    }
    if (this.settingsPage === 'backup') {
      return '备份与恢复';
    }
    if (this.settingsPage === 'about') {
      return '关于';
    }
    return '设置';
  }

  private appearanceSummary(): string {
    return `${ACCENTS[this.st.accentIndex].name} · ${settings.uiLabel()} · 动效${settings.motionLabel()}`;
  }

  private playbackSummary(): string {
    return `${this.st.defaultSpeed}x · ${this.st.rememberProgress ? '记住进度' : '不记进度'}`;
  }

  private lyricsSummary(): string {
    return `正文${Math.round(this.st.lyricScale * 100)}% · 译文${Math.round(this.st.transScale * 100)}%`;
  }

  /**
   * 页签栏与迷你播放器的底色：通透度越高，alpha 越低。
   * 基色固定 #38322E，只改 alpha 通道；模糊强度在调用处按同一比例给。
   */
  private chromeBg(): string {
    const alpha = Math.round(255 * (1 - this.st.chromeGlass / 100 * 0.7));
    const h = alpha.toString(16).toUpperCase();
    return `#${h.length < 2 ? '0' + h : h}38322E`;
  }

  private librarySummary(): string {
    const sort = this.st.sortMode === 0 ? '按标题' : (this.st.sortMode === 1 ? '按艺术家' : '按时长');
    return `${sort} · 已下载 ${this.dl.doneSongs.length} 首`;
  }

  private storageSummary(): string {
    if (!this.storageState.ready) {
      return '点开统计沙箱占用';
    }
    return `已用 ${formatBytes(this.storageState.total())} · 缓存 ${formatBytes(this.storageState.cache)}`;
  }

  private onlineSummary(): string {
    const who = this.auth.loggedIn ? this.auth.nickname : '未登录';
    return `${who} · ${settings.onlineQualityLabel()}`;
  }

  @Builder
  speedChip(v: number) {
    Text(`${v}x`)
      .fontSize(11)
      .fontColor(Math.abs(this.st.defaultSpeed - v) < 0.01 ? '#241C18' : TEXT_SUB)
      .height(28)
      .layoutWeight(1)
      .borderRadius(14)
      .backgroundColor(Math.abs(this.st.defaultSpeed - v) < 0.01 ? settings.accent() : '#14FFFFFF')
      .textAlign(TextAlign.Center)
      .onClick(() => {
        settings.setDefaultSpeed(v);
        audioPlayer.setSpeed(v);
      })
  }

  /** 底部页签与迷你播放器的通透度：越大底色越透、背景模糊越强 */
  @Builder
  chromeGlassSlider() {
    Column({ space: 8 }) {
      Row() {
        Text('页签与播放器通透度')
          .fontSize(14)
          .fontColor(TEXT_MAIN)
          .layoutWeight(1)
        Text(this.st.chromeGlass <= 0 ? '实心' : `${Math.round(this.st.chromeGlass)}%`)
          .fontSize(11)
          .fontColor(TEXT_SUB)
      }
      .width('100%')

      Slider({
        value: this.st.chromeGlass,
        min: 0,
        max: 100,
        step: 5
      })
        .blockColor(settings.accent())
        .trackColor('#33FFFFFF')
        .selectedColor(settings.accent())
        .trackThickness(3)
        .blockSize({ width: 14, height: 14 })
        .width('100%')
        .onChange((v: number, mode: SliderChangeMode) => {
          settings.state.chromeGlass = v;
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            settings.setChromeGlass(v);
          }
        })
    }
    .width('100%')
    .padding({ top: 12, bottom: 10, left: 14, right: 14 })
  }

  /** 歌词正文字号：拖动即时预览，松手落盘 */
  @Builder
  lyricBodySlider() {
    Column({ space: 8 }) {
      Row() {
        Text('歌词正文字号')
          .fontSize(14)
          .fontColor(TEXT_MAIN)
          .layoutWeight(1)
        Text(`${Math.round(this.st.lyricScale * 100)}%`)
          .fontSize(11)
          .fontColor(TEXT_SUB)
      }
      .width('100%')

      Slider({
        value: this.st.lyricScale,
        min: 0.7,
        max: 2.0,
        step: 0.05
      })
        .blockColor(settings.accent())
        .trackColor('#33FFFFFF')
        .selectedColor(settings.accent())
        .trackThickness(3)
        .blockSize({ width: 14, height: 14 })
        .width('100%')
        .onChange((v: number, mode: SliderChangeMode) => {
          settings.state.lyricScale = v;
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            settings.setLyricScale(v);
          }
        })
    }
    .width('100%')
    .padding({ top: 12, bottom: 10, left: 14, right: 14 })
  }

  /** 翻译行字号：与正文分开调，正文调大时译文不必跟着变粗 */
  @Builder
  lyricTransSlider() {
    Column({ space: 8 }) {
      Row() {
        Text('翻译字号')
          .fontSize(14)
          .fontColor(TEXT_MAIN)
          .layoutWeight(1)
        Text(`${Math.round(this.st.transScale * 100)}%`)
          .fontSize(11)
          .fontColor(TEXT_SUB)
      }
      .width('100%')

      Slider({
        value: this.st.transScale,
        min: 0.7,
        max: 2.0,
        step: 0.05
      })
        .blockColor(settings.accent())
        .trackColor('#33FFFFFF')
        .selectedColor(settings.accent())
        .trackThickness(3)
        .blockSize({ width: 14, height: 14 })
        .width('100%')
        .onChange((v: number, mode: SliderChangeMode) => {
          settings.state.transScale = v;
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            settings.setTransScale(v);
          }
        })
    }
    .width('100%')
    .padding({ top: 12, bottom: 10, left: 14, right: 14 })
  }

  @Builder
  uiScaleChip(label: string, value: number) {
    Text(label)
      .fontSize(11)
      .fontColor(Math.abs(this.st.uiScale - value) < 0.02 ? '#241C18' : TEXT_SUB)
      .height(28)
      .padding({ left: 12, right: 12 })
      .borderRadius(14)
      .backgroundColor(Math.abs(this.st.uiScale - value) < 0.02 ? settings.accent() : '#14FFFFFF')
      .textAlign(TextAlign.Center)
      .onClick(() => {
        settings.setUiScale(value);
      })
  }

  @Builder
  motionChip(label: string, level: number) {
    Text(label)
      .fontSize(11)
      .fontColor(this.st.motionLevel === level ? '#241C18' : TEXT_SUB)
      .height(28)
      .padding({ left: 12, right: 12 })
      .borderRadius(14)
      .backgroundColor(this.st.motionLevel === level ? settings.accent() : '#14FFFFFF')
      .textAlign(TextAlign.Center)
      .onClick(() => {
        settings.setMotionLevel(level);
      })
  }

  private totalDurationText(): string {
    let total = 0;
    for (let i = 0; i < this.lib.songs.length; i++) {
      total += this.lib.songs[i].durationMs;
    }
    const minutes = Math.round(total / 60000);
    if (minutes < 60) {
      return `${minutes} 分钟`;
    }
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    return `${h} 小时 ${m} 分`;
  }

  @Builder
  playlistList() {
    Column() {
      Row() {
        Text(`共 ${this.playlistsState.lists.length} 个歌单`)
          .fontSize(11)
          .fontColor(TEXT_SUB)
        Blank()
        Text('＋ 新建歌单')
          .fontSize(11)
          .fontColor(settings.accent())
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(12)
          .backgroundColor(settings.accentSoft(0.10))
          .onClick(() => {
            this.newName = '';
            this.showCreate = true;
          })
      }
      .width('100%')
      .margin({ top: 8, bottom: 8 })

      if (this.playlistsState.lists.length === 0) {
        Column({ space: 8 }) {
          Text('还没有歌单')
            .fontSize(13)
            .fontColor(TEXT_SUB)
          Text('点右上角新建，再到「歌曲」里长按加入')
            .fontSize(10)
            .fontColor('#5A4A42')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 2 }) {
          ForEach(this.playlistsState.lists, (list: Playlist) => {
            ListItem() {
              Row({ space: 12 }) {
                Column()
                  .width(44)
                  .height(44)
                  .borderRadius(10)
                  .backgroundColor('#1FFFFFFF')
                Column({ space: 4 }) {
                  Text(list.name)
                    .fontSize(14)
                    .fontColor(TEXT_MAIN)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(`${list.paths.length} 首`)
                    .fontSize(10)
                    .fontColor(TEXT_SUB)
                    .width('100%')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Text('›')
                  .fontSize(18)
                  .fontColor('#4D423C')
              }
              .width('100%')
              .padding({ top: 10, bottom: 10, left: 6, right: 6 })
              .onClick(() => {
                this.playlistId = list.id;
              })
              .gesture(LongPressGesture({ repeat: false })
                .onAction(() => {
                  this.confirmDeletePlaylist(list);
                }))
            }
          }, (list: Playlist) => `${list.id}_${this.playlistsState.version}`)
        }
        .layoutWeight(1)
        .width('100%')
        .contentEndOffset(this.chromeInset())
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  playlistDetail() {
    Column() {
      Row({ space: 8 }) {
        Text('‹ 全部歌单')
          .fontSize(11)
          .fontColor(settings.accent())
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(12)
          .backgroundColor(settings.accentSoft(0.10))
          .onClick(() => {
            this.playlistId = '';
          })
        Text(this.currentPlaylistName())
          .fontSize(11)
          .fontColor(TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('播放全部')
          .fontSize(11)
          .fontColor('#1E1A18')
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(12)
          .backgroundColor(settings.accent())
          .onClick(() => {
            this.playPlaylist();
          })
      }
      .width('100%')
      .margin({ top: 8, bottom: 4 })

      if (playlists.songsOf(this.playlistId).length === 0) {
        Column({ space: 8 }) {
          Text('歌单是空的')
            .fontSize(13)
            .fontColor(TEXT_SUB)
          Text('到「歌曲」里长按一首歌，选「加入歌单」')
            .fontSize(10)
            .fontColor('#5A4A42')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        this.songList(playlists.songsOf(this.playlistId), 1)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  createPlaylistDialog() {
    Column() {
      Column({ space: 14 }) {
        Text('新建歌单')
          .fontSize(15)
          .fontColor(TEXT_MAIN)
        TextInput({ placeholder: '歌单名称' })
          .placeholderColor('#6B5D56')
          .placeholderFont({ size: 12 })
          .fontColor(TEXT_MAIN)
          .fontSize(13)
          .height(44)
          .backgroundColor('#1FFFFFFF')
          .borderRadius(12)
          .caretColor(settings.accent())
          .onChange((value: string) => {
            this.newName = value;
          })
        Row({ space: 10 }) {
          Button('取消')
            .fontSize(13)
            .fontColor(TEXT_SUB)
            .backgroundColor('#1FFFFFFF')
            .height(42)
            .layoutWeight(1)
            .borderRadius(21)
            .onClick(() => {
              this.showCreate = false;
            })
          Button('创建')
            .fontSize(13)
            .fontColor('#1E1A18')
            .backgroundColor(settings.accent())
            .height(42)
            .layoutWeight(1)
            .borderRadius(21)
            .onClick(() => {
              this.confirmCreatePlaylist();
            })
        }
        .width('100%')
      }
      .width('80%')
      .padding(20)
      .borderRadius(22)
      .backgroundColor('#2E2521')
      .borderWidth(1)
      .borderColor('#1FFFFFFF')
      .transition(this.dialogTransition())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#99000000')
    .transition(this.backdropTransition())
  }

  @Builder
  pickerOverlay() {
    Column() {
      Column({ space: 10 }) {
        Row() {
          Text('加入歌单')
            .fontSize(15)
            .fontColor(TEXT_MAIN)
          Blank()
          Text('✕')
            .fontSize(15)
            .fontColor(TEXT_SUB)
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.pickerPath = '';
              this.pickerSong = null;
            })
        }
        .width('100%')

        List({ space: 2 }) {
          ForEach(this.playlistsState.lists, (list: Playlist) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(list.name)
                  .fontSize(13)
                  .fontColor(TEXT_MAIN)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(`${list.paths.length} 首`)
                  .fontSize(10)
                  .fontColor(TEXT_SUB)
              }
              .width('100%')
              .padding({ top: 12, bottom: 12, left: 4, right: 4 })
              .onClick(() => {
                this.addToPlaylist(list.id);
              })
            }
          }, (list: Playlist) => `${list.id}_${this.playlistsState.version}`)
        }
        .width('100%')
        .height(220)
        .scrollBar(BarState.Off)

        Text('＋ 新建歌单并加入')
          .fontSize(12)
          .fontColor(settings.accent())
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
          .borderRadius(12)
          .backgroundColor(settings.accentSoft(0.10))
          .onClick(() => {
            this.newName = '';
            this.showCreate = true;
          })
      }
      .width('84%')
      .padding(18)
      .borderRadius(22)
      .backgroundColor('#2E2521')
      .borderWidth(1)
      .borderColor('#1FFFFFFF')
      .transition(this.dialogTransition())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#99000000')
    .transition(this.backdropTransition())
  }

  @Builder
  searchRow() {
    Row({ space: 10 }) {
      TextInput({ placeholder: '搜索歌曲、艺术家、专辑' })
        .placeholderColor('#6B5D56')
        .placeholderFont({ size: 12 })
        .fontColor(TEXT_MAIN)
        .fontSize(13)
        .height(40)
        .layoutWeight(1)
        .padding({ left: 14, right: 14 })
        .backgroundColor('#14FFFFFF')
        .borderRadius(20)
        .caretColor(settings.accent())
        .onChange((value: string) => {
          library.setQuery(value);
        })

      // 圆底加号：导入本地音频
      Text('＋')
        .fontSize(21)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1E1A18')
        .width(40)
        .height(40)
        .borderRadius(20)
        .textAlign(TextAlign.Center)
        .backgroundColor(settings.accent())
        .onClick(() => {
          this.pickFiles();
        })
    }
    .width('100%')
    .margin({ bottom: 10 })
  }

  @Builder
  libQuickRow() {
    Row({ space: 10 }) {
      this.quickButton('收藏歌曲', 1, `${this.favoriteSongs.length} 首`)
      this.quickButton('下载歌曲', 2, `${this.dl.doneSongs.length} 首`)
    }
    .width('100%')
    .margin({ bottom: 2 })
  }

  /** 两个大按钮：切到收藏 / 下载，再点一次回本地 */
  @Builder
  quickButton(label: string, section: number, count: string) {
    Row({ space: 6 }) {
      Text(label)
        .fontSize(13)
        .fontWeight(this.libSection === section ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.libSection === section ? '#1E1A18' : TEXT_MAIN)
      Text(count)
        .fontSize(10)
        .fontColor(this.libSection === section ? '#1E1A18' : TEXT_SUB)
    }
    .layoutWeight(1)
    .height(42)
    .justifyContent(FlexAlign.Center)
    .borderRadius(21)
    .backgroundColor(this.libSection === section ? settings.accent() : '#1FFFFFFF')
    .onClick(() => {
      if (this.libSection === section) {
        this.libSection = 0;
        return;
      }
      this.libSection = section;
      this.favGroupKey = '';
      this.playlistId = '';
      if (section === 1) {
        this.favTab = 0;
        this.refreshFavorites();
      } else {
        this.dlTab = 0;
        this.onModeChanged(8);
      }
    })
  }

  /** 分类行：跟着上面两个大按钮变（本地 / 收藏 / 下载各有自己的分类） */
  @Builder
  sectionChips() {
    Row({ space: 4 }) {
      if (this.libSection === 0) {
        this.segmentChip('歌曲', 0)
        this.segmentChip('专辑', 1)
        this.segmentChip('艺术家', 2)
        this.segmentChip('歌单', 3)
        this.segmentChip('最近', 4)
      } else if (this.libSection === 1) {
        this.favChip('歌曲', 0)
        this.favChip('专辑', 1)
        this.favChip('艺术家', 2)
      } else {
        this.dlChip('已完成', 0)
        this.dlChip('下载中', 1)
      }
    }
    .width('100%')
    .margin({ top: 10, bottom: 2 })
  }

  @Builder
  favChip(label: string, tab: number) {
    Text(label)
      .fontSize(11)
      .fontColor(this.favTab === tab ? '#1E1A18' : TEXT_SUB)
      .fontWeight(this.favTab === tab ? FontWeight.Medium : FontWeight.Normal)
      .textAlign(TextAlign.Center)
      .height(30)
      .padding({ left: 12, right: 12 })
      .borderRadius(15)
      .backgroundColor(this.favTab === tab ? settings.accent() : '#14FFFFFF')
      .onClick(() => {
        this.favTab = tab;
        this.favGroupKey = '';
      })
  }

  @Builder
  dlChip(label: string, tab: number) {
    Text(label)
      .fontSize(11)
      .fontColor(this.dlTab === tab ? '#1E1A18' : TEXT_SUB)
      .fontWeight(this.dlTab === tab ? FontWeight.Medium : FontWeight.Normal)
      .textAlign(TextAlign.Center)
      .height(30)
      .padding({ left: 12, right: 12 })
      .borderRadius(15)
      .backgroundColor(this.dlTab === tab ? settings.accent() : '#14FFFFFF')
      .onClick(() => {
        this.dlTab = tab;
      })
  }

  @Builder
  segmentChip(label: string, mode: number) {
    Text(label)
      .fontSize(11)
      .fontColor(this.viewMode === mode ? '#1E1A18' : TEXT_SUB)
      .fontWeight(this.viewMode === mode ? FontWeight.Medium : FontWeight.Normal)
      .textAlign(TextAlign.Center)
      .height(30)
      .padding({ left: 7, right: 7 })
      .borderRadius(16)
      .backgroundColor(this.viewMode === mode ? settings.accent() : '#14FFFFFF')
      .onClick(() => {
        this.viewMode = mode;
        this.groupKey = '';
        this.playlistId = '';
        this.onModeChanged(mode);
      })
  }

  /** 统计内容本身（不再自带 Scroll，设置页里包一层就行） */
  @Builder
  statsContent() {
    Column({ space: 14 }) {
      Row() {
        Text('播放统计')
          .fontSize(12)
          .fontColor(TEXT_SUB)
        Blank()
        Text('清空历史')
          .fontSize(10)
          .fontColor('#FF6B6B')
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(10)
          .backgroundColor('#14FFFFFF')
          .onClick(() => {
            this.confirmClearHistory();
          })
      }
      .width('100%')
      .margin({ top: 6 })

      if (this.statsState.totalPlays === 0) {
        Column({ space: 8 }) {
          Text('还没有播放记录')
            .fontSize(13)
            .fontColor(TEXT_SUB)
          Text('每首歌起播时会记一次，统计由此而来')
            .fontSize(10)
            .fontColor('#5A4A42')
        }
        .width('100%')
        .padding({ top: 60, bottom: 60 })
      } else {
        Row({ space: 10 }) {
          this.metricCard('累计播放', `${this.statsState.totalPlays} 次`)
          this.metricCard('听过曲目', `${this.statsState.distinctSongs} 首`)
        }
        .width('100%')

        Row({ space: 10 }) {
          this.metricCard('收听时长', this.listenTimeText())
          this.metricCard('陪伴天数', `${this.companionDays()} 天`)
        }
        .width('100%')

        Column({ space: 10 }) {
          Text('最近 7 天')
            .fontSize(11)
            .fontColor(TEXT_SUB)
            .width('100%')
          Row({ space: 8 }) {
            ForEach(this.statsState.days, (day: StatsDayItem) => {
              Column({ space: 6 }) {
                Text(`${day.count}`)
                  .fontSize(9)
                  .fontColor(day.count > 0 ? TEXT_MAIN : '#4A403A')
                Stack({ alignContent: Alignment.Bottom }) {
                  Column().width('100%').height(86).borderRadius(6).backgroundColor('#08FFFFFF')
                  Column().width('100%').height(this.barHeight(day.count)).borderRadius(6)
                    .backgroundColor(day.isToday ? settings.accent() : settings.accentSoft(0.45))
                }
                .width('100%')
                .height(86)
                Text(day.label).fontSize(8).fontColor('#6B5D56')
              }
              .layoutWeight(1)
            }, (day: StatsDayItem) => day.label)
          }
          .width('100%')
        }
        .width('100%')
        .padding(14)
        .borderRadius(16)
        .backgroundColor('#0DFFFFFF')

        Column({ space: 2 }) {
          Row() {
            Text('最常听')
              .fontSize(11)
              .fontColor(TEXT_SUB)
            Blank()
            Text('次数')
              .fontSize(9)
              .fontColor('#6B5D56')
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 12, bottom: 4 })

          this.statRow(0)
          this.statRow(1)
          this.statRow(2)
          this.statRow(3)
          this.statRow(4)
          this.statRow(5)
          this.statRow(6)
          this.statRow(7)
        }
        .width('100%')
        .borderRadius(16)
        .backgroundColor('#0DFFFFFF')

        Text('收听时长为「次数 × 曲目时长」的估算值，快进和切歌会让它比真实值偏长')
          .fontSize(9)
          .fontColor('#4A403A')
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 8 })
      }
    }
    .width('100%')

  }

  // ─────────────────── 在线（网易云） ───────────────────

  @Builder
  onlineSearchRow() {
    Row({ space: 8 }) {
      TextInput({ text: this.online.keyword, placeholder: '搜索网易云：歌名、歌手、歌单' })
        .placeholderColor('#6B5D56')
        .placeholderFont({ size: 12 })
        .fontColor(TEXT_MAIN)
        .fontSize(13)
        .height(40)
        .layoutWeight(1)
        .padding({ left: 14, right: 14 })
        .backgroundColor('#14FFFFFF')
        .borderRadius(20)
        .caretColor(settings.accent())
        .onChange((value: string) => {
          this.online.keyword = value;
        })
        .onSubmit(() => {
          this.getUIContext().getFocusController().clearFocus();
          netease.search(this.online.keyword);
        })

      if (this.online.hasSearched) {
        Text('清除')
          .fontSize(11)
          .fontColor(TEXT_SUB)
          .height(40)
          .padding({ left: 12, right: 12 })
          .textAlign(TextAlign.Center)
          .borderRadius(20)
          .backgroundColor('#14FFFFFF')
          .onClick(() => {
            netease.clearSearch();
          })
      }

      Text('搜索')
        .fontSize(11)
        .fontColor('#1E1A18')
        .height(40)
        .padding({ left: 14, right: 14 })
        .textAlign(TextAlign.Center)
        .borderRadius(20)
        .backgroundColor(settings.accent())
        .onClick(() => {
          // 收起键盘，否则播放条会被输入法挡住
          this.getUIContext().getFocusController().clearFocus();
          netease.search(this.online.keyword);
        })
    }
    .width('100%')
    .margin({ bottom: 10 })
  }

  @Builder
  onlineTabRow() {
    Row({ space: 6 }) {
      this.onlineTabChip('单曲', 0)
      this.onlineTabChip('歌单', 1)
      this.onlineTabChip('专辑', 2)
      Blank()
      if (this.online.searching) {
        LoadingProgress()
          .width(16)
          .height(16)
          .color(settings.accent())
      }
    }
    .width('100%')
    .margin({ bottom: 6 })
  }

  @Builder
  onlineTabChip(label: string, tab: number) {
    Text(label)
      .fontSize(11)
      .fontColor(this.online.tab === tab ? '#1E1A18' : TEXT_SUB)
      .height(28)
      .padding({ left: 14, right: 14 })
      .borderRadius(14)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.online.tab === tab ? settings.accent() : '#14FFFFFF')
      .onClick(() => {
        netease.setTab(tab);
      })
  }

  @Builder
  onlineResultArea() {
    if (this.online.searching && this.onlineVisibleCount() === 0) {
      this.onlineLoading('正在搜索…')
    } else if (this.online.message.length > 0 && this.onlineVisibleCount() === 0) {
      this.onlineEmpty(this.online.message)
    } else if (this.online.tab === 0) {
      List({ space: 2 }) {
        ForEach(this.online.songs, (song: Song, index: number) => {
          ListItem() {
            this.onlineSongRow(song, index, this.online.songs)
          }
        }, (song: Song) => `ns_${song.path}`)
      }
      .width('100%')
      .layoutWeight(1)
      .contentEndOffset(this.chromeInset())
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    } else {
      List({ space: 2 }) {
        ForEach(this.online.tab === 1 ? this.online.playlistResults : this.online.albumResults,
          (p: NeteasePlaylist) => {
            ListItem() {
              this.onlinePlaylistRow(p, this.online.tab === 1)
            }
          }, (p: NeteasePlaylist) => `np_${this.online.tab}_${p.id}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  @Builder
  onlineLoading(text: string) {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(28)
        .height(28)
        .color(settings.accent())
      Text(text)
        .fontSize(11)
        .fontColor(TEXT_SUB)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  onlineEmpty(text: string) {
    Column({ space: 10 }) {
      Text(text)
        .fontSize(12)
        .fontColor(TEXT_SUB)
        .textAlign(TextAlign.Center)
      Text('换个关键词试试，或检查网络')
        .fontSize(10)
        .fontColor('#5A4A42')
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  onlineHome() {
    if (this.online.homeLoading && this.online.homeBlocks.length === 0) {
      this.onlineLoading('正在加载推荐…')
    } else if (this.online.homeBlocks.length === 0) {
      Column({ space: 12 }) {
        Text(this.online.homeMessage.length > 0 ? this.online.homeMessage : '暂时没有拉到内容')
          .fontSize(12)
          .fontColor(TEXT_SUB)
          .textAlign(TextAlign.Center)
        Text('重试')
          .fontSize(11)
          .fontColor('#1E1A18')
          .height(32)
          .padding({ left: 18, right: 18 })
          .borderRadius(16)
          .textAlign(TextAlign.Center)
          .backgroundColor(settings.accent())
          .onClick(() => {
            netease.loadHome(true);
          })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      Scroll() {
        Column() {
          if (this.online.homeLoading && !this.hasReadyBlock()) {
            Row({ space: 8 }) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color(settings.accent())
              Text('正在加载推荐…')
                .fontSize(11)
                .fontColor(TEXT_SUB)
            }
            .width('100%')
            .padding({ top: 20, bottom: 20 })
            .justifyContent(FlexAlign.Center)
          }

          ForEach(this.online.homeBlocks, (block: HomeBlock) => {
            if (block.state === HomeBlockState.READY) {
              this.homeSectionHeader(block.glyph, block.title)
              if (block.kind === HomeBlockKind.SONGS) {
                Column() {
                  ForEach(block.songs, (song: Song, index: number) => {
                    this.homeSongRow(song, index, block.songs)
                  }, (song: Song) => `hb_${block.key}_${song.path}`)
                }
                .width('100%')
              } else if (block.kind === HomeBlockKind.RADAR) {
                Scroll() {
                  Row({ space: 12 }) {
                    ForEach(block.playlists, (p: NeteasePlaylist) => {
                      this.onlinePlaylistCard(p)
                    }, (p: NeteasePlaylist) => `radar_${p.id}`)
                  }
                  .padding({ top: 2, bottom: 4 })
                }
                .width('100%')
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .edgeEffect(EdgeEffect.Spring)
              } else {
                this.homePlaylistGrid(block.playlists)
              }
            }
          }, (block: HomeBlock) => block.key)

          Text('内容来自网易云音乐公开接口，仅用于个人试听')
            .fontSize(9)
            .fontColor('#4A403A')
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 18, bottom: 10 })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .contentEndOffset(this.chromeInset())
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  /** 首页分段标题：小图标 + 加粗标题，跟安卓版 SectionHeader 一致 */
  @Builder
  homeSectionHeader(glyph: string, title: string) {
    Row({ space: 7 }) {
      Text(glyph)
        .fontSize(14)
        .fontColor(settings.accent())
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(settings.accent())
        .letterSpacing(0.6)
    }
    .width('100%')
    .padding({ top: 18, bottom: 8 })
  }

  /** 首页歌曲行：序号 + 封面 + 曲名/歌手 + 更多 */
  @Builder
  homeSongRow(song: Song, index: number, queue: Song[]) {
    Row({ space: 10 }) {
      Text(`${index + 1}`)
        .fontSize(11)
        .fontColor(this.isCurrent(song) ? settings.accent() : '#6B5D56')
        .width(16)
        .textAlign(TextAlign.Center)

      this.songCover(song, 42)

      Column({ space: 3 }) {
        Text(song.title)
          .fontSize(14)
          .fontColor(this.isCurrent(song) ? settings.accent() : TEXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(song.artist.length > 0 ? song.artist : '未知艺术家')
          .fontSize(10)
          .fontColor(TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('⋯')
        .fontSize(18)
        .fontColor('#7A6A62')
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.showOnlineMenu(song);
        })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .onClick(() => {
      playback.playSong(song, queue);
    })
  }

  /** 三列歌单网格，行高按内容宽度算，避免 Grid 在 Scroll 里拿不到高度 */
  @Builder
  homePlaylistGrid(lists: NeteasePlaylist[]) {
    Column({ space: 14 }) {
      ForEach(this.playlistChunks(lists), (row: NeteasePlaylist[], ri: number) => {
        Row({ space: 10 }) {
          ForEach(row, (p: NeteasePlaylist) => {
            this.homePlaylistCell(p)
          }, (p: NeteasePlaylist) => `fg_${p.id}`)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (row: NeteasePlaylist[], ri: number) => `prow_${ri}`)
    }
    .width('100%')
  }

  @Builder
  homePlaylistCell(p: NeteasePlaylist) {
    Column({ space: 5 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (p.coverUrl.length > 0) {
          Image(p.coverUrl)
            .width('100%')
            .aspectRatio(1)
            .borderRadius(10)
            .objectFit(ImageFit.Cover)
            .draggable(false)
        } else {
          Column()
            .width('100%')
            .aspectRatio(1)
            .borderRadius(10)
            .backgroundColor('#1FFFFFFF')
        }
        Text(this.countText(p.playCount))
          .fontSize(9)
          .fontColor('#F5EDE8')
          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .borderRadius(8)
          .backgroundColor('#66000000')
          .margin({ right: 5, bottom: 5 })
      }
      .width('100%')

      Text(p.name)
        .fontSize(11)
        .lineHeight(16)
        .height(32)
        .fontColor(TEXT_MAIN)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width((this.contentWidth - (this.gridCols - 1) * 10) / this.gridCols)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
    .onClick(() => {
      netease.openPlaylist(p);
    })
  }

  /** 封面：本地优先内存缩略图，在线直接用 URL，都没有就留空块 */
  @Builder
  songCover(song: Song | null, size: number) {
    if (song !== null && !song.isRemote() && this.st.showThumbs && cover.thumbOf(song.path) !== null) {
      Image(cover.thumbOf(song.path) as image.PixelMap)
        .width(size)
        .height(size)
        .borderRadius(size * 0.22)
        .objectFit(ImageFit.Cover)
        .draggable(false)
    } else if (song !== null && song.coverUrl.length > 0) {
      Image(song.coverUrl)
        .width(size)
        .height(size)
        .borderRadius(size * 0.22)
        .objectFit(ImageFit.Cover)
        .draggable(false)
    } else {
      Column()
        .width(size)
        .height(size)
        .borderRadius(size * 0.22)
        .backgroundColor('#14FFFFFF')
    }
  }

  @Builder
  onlinePlaylistCard(p: NeteasePlaylist) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (p.coverUrl.length > 0) {
          Image(p.coverUrl)
            .width(124)
            .height(124)
            .borderRadius(12)
            .objectFit(ImageFit.Cover)
            .draggable(false)
        } else {
          Column()
            .width(124)
            .height(124)
            .borderRadius(12)
            .backgroundColor('#1FFFFFFF')
        }
        Text(this.countText(p.playCount))
          .fontSize(9)
          .fontColor('#F5EDE8')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(8)
          .backgroundColor('#66000000')
          .margin({ right: 6, bottom: 6 })
      }
      .width(124)
      .height(124)

      Text(p.name)
        .fontSize(11)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(124)
        .textAlign(TextAlign.Start)
    }
    .width(124)
    .onClick(() => {
      netease.openPlaylist(p);
    })
  }

  @Builder
  onlinePlaylistRow(p: NeteasePlaylist, isPlaylist: boolean) {
    Row({ space: 12 }) {
      if (p.coverUrl.length > 0) {
        Image(p.coverUrl)
          .width(48)
          .height(48)
          .borderRadius(10)
          .objectFit(ImageFit.Cover)
          .draggable(false)
      } else {
        Column()
          .width(48)
          .height(48)
          .borderRadius(10)
          .backgroundColor('#1FFFFFFF')
      }
      Column({ space: 4 }) {
        Text(p.name)
          .fontSize(13)
          .fontColor(TEXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.onlinePlaylistSub(p, isPlaylist))
          .fontSize(10)
          .fontColor(TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(18)
        .fontColor('#4D423C')
    }
    .width('100%')
    .padding({ top: 8, bottom: 8, left: 4, right: 8 })
    .borderRadius(12)
    .onClick(() => {
      if (isPlaylist) {
        netease.openPlaylist(p);
      } else {
        netease.openAlbum(p);
      }
    })
  }

  @Builder
  onlineSongRow(song: Song, index: number, queue: Song[]) {
    Row({ space: 10 }) {
      Row()
        .width(3)
        .height(20)
        .borderRadius(2)
        .backgroundColor(this.isCurrent(song) ? settings.accent() : '#00000000')

      if (song.coverUrl.length > 0) {
        Image(song.coverUrl)
          .width(44)
          .height(44)
          .borderRadius(9)
          .objectFit(ImageFit.Cover)
          .draggable(false)
      } else {
        Column() {
          Text(`${index + 1}`)
            .fontSize(11)
            .fontColor(this.isCurrent(song) ? settings.accent() : '#5A4A42')
        }
        .width(44)
        .height(44)
        .borderRadius(9)
        .backgroundColor('#14FFFFFF')
        .justifyContent(FlexAlign.Center)
      }

      Column({ space: 3 }) {
        Text(song.title)
          .fontSize(14)
          .fontColor(this.isCurrent(song) ? settings.accent() : TEXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.subtitle(song))
          .fontSize(10)
          .fontColor(TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.favPaths.indexOf(song.path) >= 0) {
        Image($r('app.media.ic_heart'))
          .width(12)
          .height(12)
          .fillColor(settings.accent())
          .margin({ right: 5 })
          .draggable(false)
      }

      if (this.online.resolvingTitle === song.title) {
        LoadingProgress()
          .width(16)
          .height(16)
          .color(settings.accent())
      } else {
        Text(formatTime(song.durationMs))
          .fontSize(10)
          .fontColor(TEXT_SUB)
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 4, right: 8 })
    .borderRadius(12)
    .backgroundColor(this.isCurrent(song) ? settings.accentSoft(0.08) : '#00000000')
    .onClick(() => {
      playback.playSong(song, queue);
    })
    .gesture(LongPressGesture({ repeat: false })
      .onAction(() => {
        this.showOnlineMenu(song);
      }))
  }

  @Builder
  onlineDetail() {
    Column() {
      Row({ space: 8 }) {
        Text(`‹ ${this.online.detailKind === 'album' ? '返回专辑' : '返回歌单'}`)
          .fontSize(11)
          .fontColor(settings.accent())
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(12)
          .backgroundColor(settings.accentSoft(0.10))
          .onClick(() => {
            netease.closeDetail();
          })
        Blank()
        Text('播放全部')
          .fontSize(11)
          .fontColor('#1E1A18')
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(12)
          .backgroundColor(settings.accent())
          .onClick(() => {
            if (this.online.detailSongs.length > 0) {
              playback.setQueue(this.online.detailSongs);
              playback.playIndex(0);
            }
          })
      }
      .width('100%')
      .margin({ top: 2, bottom: 8 })

      Row({ space: 12 }) {
        if (this.online.detailCover.length > 0) {
          Image(this.online.detailCover)
            .width(84)
            .height(84)
            .borderRadius(14)
            .objectFit(ImageFit.Cover)
            .draggable(false)
        }
        Column({ space: 5 }) {
          Text(this.online.detailTitle)
            .fontSize(15)
            .fontColor(TEXT_MAIN)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.online.detailDesc.length > 0) {
            Text(this.online.detailDesc)
              .fontSize(10)
              .fontColor(TEXT_SUB)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          Text(`${this.online.detailSongs.length} 首`)
            .fontSize(10)
            .fontColor('#5A4A42')
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .margin({ bottom: 8 })

      if (this.online.detailLoading) {
        this.onlineLoading('正在读取曲目…')
      } else if (this.online.detailSongs.length === 0) {
        this.onlineEmpty(this.online.detailMessage.length > 0 ? this.online.detailMessage : '没有曲目')
      } else {
        List({ space: 2 }) {
          ForEach(this.online.detailSongs, (song: Song, index: number) => {
            ListItem() {
              this.onlineSongRow(song, index, this.online.detailSongs)
            }
          }, (song: Song) => `nd_${song.path}`)
        }
        .width('100%')
        .layoutWeight(1)
        .contentEndOffset(this.chromeInset())
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  // ─────────────────── 下载管理 ───────────────────

  @Builder
  downloadChip(label: string, danger: boolean, action: () => void) {
    Text(label)
      .fontSize(10)
      .fontColor(danger ? '#FF6B6B' : settings.accent())
      .height(26)
      .padding({ left: 12, right: 12 })
      .borderRadius(13)
      .textAlign(TextAlign.Center)
      .backgroundColor(danger ? '#1AFF6B6B' : settings.accentSoft(0.10))
      .onClick(action)
  }

  @Builder
  downloadView() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text(`已下载 ${this.dl.doneSongs.length} 首`)
            .fontSize(14)
            .fontColor(TEXT_MAIN)
          Text(this.downloadSummary())
            .fontSize(10)
            .fontColor(TEXT_SUB)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.dl.activeCount > 0) {
          this.downloadChip('全部暂停', false, () => {
            downloader.pauseAll();
          })
        } else if (this.downloadUnfinished() > 0) {
          this.downloadChip('全部继续', false, () => {
            downloader.resumeAll();
          })
        }
      }
      .width('100%')
      .padding({ top: 10, bottom: 10, left: 14, right: 14 })
      .borderRadius(16)
      .backgroundColor('#0DFFFFFF')

      if (this.dl.message.length > 0) {
        Text(this.dl.message)
          .fontSize(10)
          .fontColor(TEXT_SUB)
          .width('100%')
      }

      if (this.dlTab === 0 ? this.doneTasks().length === 0 : this.activeTasks().length === 0) {
        Column({ space: 10 }) {
          Image($r('app.media.ic_note'))
            .width(28)
            .height(28)
            .fillColor('#5A4A42')
          Text(this.dlTab === 0 ? '还没有下载完成的歌曲' : '没有正在下载的任务')
            .fontSize(13)
            .fontColor(TEXT_MAIN)
          Text('去「首页」或「探索」长按歌曲，选「下载」')
            .fontSize(10)
            .fontColor(TEXT_SUB)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.dlTab === 0 ? this.doneTasks() : this.activeTasks(), (t: DownloadTask) => {
            ListItem() {
              this.downloadRow(t)
            }
          }, (t: DownloadTask) => `dl_${t.songPath}_${t.status}`)
        }
        .width('100%')
        .layoutWeight(1)
        .contentEndOffset(this.chromeInset())
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }

      if (this.dlTab === 0 && this.dl.doneSongs.length > 0) {
        Row({ space: 8 }) {
          Text('文件保存在应用沙箱，卸载应用会一起删除')
            .fontSize(9)
            .fontColor('#4A403A')
            .layoutWeight(1)
          Text('清空已完成')
            .fontSize(9)
            .fontColor('#FF6B6B')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => {
              this.confirmClearDownloads();
            })
        }
        .width('100%')
        .margin({ bottom: 4 })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  downloadRow(t: DownloadTask) {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        if (t.coverUrl.length > 0) {
          Image(t.coverUrl)
            .width(44)
            .height(44)
            .borderRadius(9)
            .objectFit(ImageFit.Cover)
            .draggable(false)
        } else {
          Column() {
            Text('♪')
              .fontSize(14)
              .fontColor('#5A4A42')
          }
          .width(44)
          .height(44)
          .borderRadius(9)
          .backgroundColor('#14FFFFFF')
          .justifyContent(FlexAlign.Center)
        }

        Column({ space: 3 }) {
          Text(t.title)
            .fontSize(13)
            .fontColor(TEXT_MAIN)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(`${t.artist}${t.quality.length > 0 ? ` · ${t.quality}` : ''}`)
            .fontSize(9)
            .fontColor(TEXT_SUB)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .onClick(() => {
          if (t.status === DownloadStatus.DONE) {
            this.playDownload(t);
          }
        })

        Text(t.statusLabel())
          .fontSize(9)
          .fontColor(this.downloadStatusColor(t))
          .maxLines(1)
      }
      .width('100%')

      if (t.status !== DownloadStatus.DONE) {
        Row({ space: 8 }) {
          Progress({ value: Math.round(t.progress() * 100), total: 100, type: ProgressType.Linear })
            .layoutWeight(1)
            .height(4)
            .color(settings.accent())
            .backgroundColor('#1FFFFFFF')
          Text(`${Math.round(t.progress() * 100)}%`)
            .fontSize(9)
            .fontColor(TEXT_SUB)
        }
        .width('100%')

        Row({ space: 8 }) {
          Text(`${formatBytes(t.downloadedBytes)}${t.totalBytes > 0 ? ` / ${formatBytes(t.totalBytes)}` : ''}`)
            .fontSize(9)
            .fontColor('#5A4A42')
            .layoutWeight(1)
          if (t.status === DownloadStatus.DOWNLOADING) {
            this.downloadChip('暂停', false, () => {
              downloader.pause(t);
            })
          } else if (t.status === DownloadStatus.PAUSED || t.status === DownloadStatus.FAILED
            || t.status === DownloadStatus.WAITING) {
            this.downloadChip(t.status === DownloadStatus.FAILED ? '重试' : '继续', false, () => {
              downloader.resume(t);
            })
          }
          this.downloadChip('取消', true, () => {
            this.confirmDeleteDownload(t);
          })
        }
        .width('100%')
      } else {
        Row({ space: 8 }) {
          Text(`${formatBytes(t.totalBytes)} · ${formatTime(t.durationMs)}`)
            .fontSize(9)
            .fontColor('#5A4A42')
            .layoutWeight(1)
          this.downloadChip('播放', false, () => {
            this.playDownload(t);
          })
          this.downloadChip('删除', true, () => {
            this.confirmDeleteDownload(t);
          })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 10, right: 10 })
    .borderRadius(14)
    .backgroundColor('#0AFFFFFF')
  }

  private downloadSummary(): string {
    let waiting = 0;
    let paused = 0;
    let failed = 0;
    for (let i = 0; i < this.dl.tasks.length; i++) {
      const st = this.dl.tasks[i].status;
      if (st === DownloadStatus.WAITING) {
        waiting++;
      } else if (st === DownloadStatus.PAUSED) {
        paused++;
      } else if (st === DownloadStatus.FAILED) {
        failed++;
      }
    }
    let out = formatBytes(this.dl.totalBytes);
    if (this.dl.activeCount > 0) {
      out += ` · 下载中 ${this.dl.activeCount}`;
    }
    if (waiting > 0) {
      out += ` · 等待 ${waiting}`;
    }
    if (paused > 0) {
      out += ` · 暂停 ${paused}`;
    }
    if (failed > 0) {
      out += ` · 失败 ${failed}`;
    }
    if (this.dl.tasks.length === 0) {
      out = '下载后可离线播放';
    }
    return out;
  }

  private downloadUnfinished(): number {
    let n = 0;
    for (let i = 0; i < this.dl.tasks.length; i++) {
      if (this.dl.tasks[i].status !== DownloadStatus.DONE) {
        n++;
      }
    }
    return n;
  }

  private downloadStatusColor(t: DownloadTask): string {
    if (t.status === DownloadStatus.DONE) {
      return '#7BC67E';
    }
    if (t.status === DownloadStatus.DOWNLOADING) {
      return settings.accent();
    }
    if (t.status === DownloadStatus.FAILED) {
      return '#FF6B6B';
    }
    return TEXT_SUB;
  }

  private playDownload(t: DownloadTask): void {
    if (t.status !== DownloadStatus.DONE) {
      return;
    }
    const song = downloader.songOf(t);
    playback.playSong(song, this.dl.doneSongs);
  }

  private confirmDeleteDownload(t: DownloadTask): void {
    this.getUIContext().showAlertDialog({
      title: '删除下载',
      message: `「${t.title}」的文件会从本机删除，在线版本不受影响。`,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#FF6B6B',
        action: () => {
          downloader.remove(t);
        }
      }
    });
  }

  private confirmClearDownloads(): void {
    this.getUIContext().showAlertDialog({
      title: '清空已完成',
      message: `将删除 ${this.dl.doneSongs.length} 个已下载文件，在线版本不受影响。`,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: '#FF6B6B',
        action: () => {
          downloader.clearDone();
        }
      }
    });
  }

  // ─────────────────── 歌手主页 ───────────────────

  @Builder
  artistTabChip(label: string, tab: number) {
    Text(label)
      .fontSize(11)
      .fontColor(this.artistSt.tab === tab ? '#1E1A18' : TEXT_SUB)
      .height(30)
      .layoutWeight(1)
      .borderRadius(15)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.artistSt.tab === tab ? settings.accent() : '#14FFFFFF')
      .onClick(() => {
        neteaseArtist.setTab(tab);
      })
  }

  @Builder
  artistOverlay() {
    Column() {
      Row() {
        Text('‹')
          .fontSize(26)
          .fontColor(TEXT_SUB)
          .width(44)
          .height(40)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            neteaseArtist.close();
          })
        Blank()
        Text('歌手')
          .fontSize(14)
          .fontColor(TEXT_MAIN)
          .letterSpacing(1)
        Blank()
        Row()
          .width(44)
          .height(40)
      }
      .width('100%')

      if (this.artistSt.loading) {
        this.onlineLoading('正在读取歌手资料…')
      } else {
        Scroll() {
          Column({ space: 12 }) {
            Row({ space: 14 }) {
              if (this.artistSt.avatarUrl.length > 0) {
                Image(this.artistSt.avatarUrl)
                  .width(72)
                  .height(72)
                  .borderRadius(36)
                  .objectFit(ImageFit.Cover)
                  .draggable(false)
              } else {
                Column() {
                  Text(this.artistSt.name.length > 0 ? this.artistSt.name.charAt(0) : '♪')
                    .fontSize(24)
                    .fontColor(TEXT_SUB)
                }
                .width(72)
                .height(72)
                .borderRadius(36)
                .backgroundColor('#1FFFFFFF')
                .justifyContent(FlexAlign.Center)
              }
              Column({ space: 5 }) {
                Text(this.artistSt.name)
                  .fontSize(19)
                  .fontColor(TEXT_MAIN)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                if (this.artistSt.alias.length > 0) {
                  Text(this.artistSt.alias)
                    .fontSize(10)
                    .fontColor(TEXT_SUB)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }
                Text(`${this.artistSt.songCount} 首单曲 · ${this.artistSt.albumCount} 张专辑 · ${this.artistSt.mvCount} 个 MV`)
                  .fontSize(9)
                  .fontColor('#5A4A42')
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ top: 4, bottom: 4 })

            if (this.artistSt.brief.length > 0) {
              Column({ space: 4 }) {
                Text(this.artistSt.brief)
                  .fontSize(10)
                  .fontColor('#8C7C74')
                  .lineHeight(16)
                  .maxLines(this.briefOpen ? 30 : 3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(this.briefOpen ? '收起' : '展开')
                  .fontSize(9)
                  .fontColor(settings.accent())
                  .onClick(() => {
                    this.briefOpen = !this.briefOpen;
                  })
              }
              .width('100%')
              .padding(12)
              .borderRadius(14)
              .backgroundColor('#0DFFFFFF')
            }

            Row({ space: 6 }) {
              this.artistTabChip('热门单曲', ArtistTab.SONG)
              this.artistTabChip('专辑', ArtistTab.ALBUM)
              this.artistTabChip('MV', ArtistTab.MV)
            }
            .width('100%')

            if (this.artistSt.tab === ArtistTab.SONG) {
              if (this.artistSt.songs.length === 0) {
                this.onlineEmpty(this.artistSt.message.length > 0 ? this.artistSt.message : '没有单曲')
              } else {
                ForEach(this.artistSt.songs, (song: Song, index: number) => {
                  this.onlineSongRow(song, index, this.artistSt.songs)
                }, (song: Song) => `ar_${song.path}`)
              }
            } else if (this.artistSt.tab === ArtistTab.ALBUM) {
              if (this.artistSt.albums.length === 0) {
                this.onlineEmpty(this.artistSt.message.length > 0 ? this.artistSt.message : '没有专辑')
              } else {
                ForEach(this.artistSt.albums, (p: NeteasePlaylist) => {
                  this.artistAlbumRow(p)
                }, (p: NeteasePlaylist) => `ara_${p.id}`)
              }
            } else {
              if (this.artistSt.mvs.length === 0) {
                this.onlineEmpty(this.artistSt.message.length > 0 ? this.artistSt.message : '没有 MV')
              } else {
                ForEach(this.artistSt.mvs, (m: NeteaseMv) => {
                  this.artistMvRow(m)
                }, (m: NeteaseMv) => `arm_${m.id}`)
              }
            }

            if (this.artistSt.hasMore) {
              Text(this.artistSt.loadingMore ? '加载中…' : '加载更多')
                .fontSize(11)
                .fontColor(settings.accent())
                .height(34)
                .width('100%')
                .textAlign(TextAlign.Center)
                .borderRadius(17)
                .backgroundColor(settings.accentSoft(0.08))
                .onClick(() => {
                  neteaseArtist.loadMore();
                })
            }

            Text('资料与作品来自网易云音乐公开接口')
              .fontSize(9)
              .fontColor('#4A403A')
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 4, bottom: 20 })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: this.topInset + 8, bottom: this.bottomInset + 8 })
    .linearGradient({
      angle: 170,
      colors: [[settings.tintBackdrop(0.16), 0.0], ['#2A211E', 0.45], ['#1A1817', 1.0]]
    })
    .transition(this.routeTransition(280, 220))
  }

  @Builder
  artistAlbumRow(p: NeteasePlaylist) {
    Row({ space: 12 }) {
      if (p.coverUrl.length > 0) {
        Image(p.coverUrl)
          .width(52)
          .height(52)
          .borderRadius(10)
          .objectFit(ImageFit.Cover)
          .draggable(false)
      } else {
        Column()
          .width(52)
          .height(52)
          .borderRadius(10)
          .backgroundColor('#1FFFFFFF')
      }
      Column({ space: 4 }) {
        Text(p.name)
          .fontSize(13)
          .fontColor(TEXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`${p.year.length > 0 ? `${p.year} · ` : ''}${p.trackCount} 首`)
          .fontSize(10)
          .fontColor(TEXT_SUB)
          .maxLines(1)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('›')
        .fontSize(18)
        .fontColor('#5A4A42')
    }
    .width('100%')
    .padding({ top: 8, bottom: 8, left: 2, right: 6 })
    .borderRadius(12)
    .onClick(() => {
      neteaseArtist.close();
      // 详情页在内容区，播放页不关就会把它盖住，点完还停在播放页
      this.showPlayer = false;
      this.showLyrics = false;
      netease.openAlbum(p);
    })
  }

  @Builder
  artistMvRow(m: NeteaseMv) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (m.coverUrl.length > 0) {
          Image(m.coverUrl)
            .width(108)
            .height(62)
            .borderRadius(9)
            .objectFit(ImageFit.Cover)
            .draggable(false)
        } else {
          Column()
            .width(108)
            .height(62)
            .borderRadius(9)
            .backgroundColor('#1FFFFFFF')
        }
        Text('▶')
          .fontSize(14)
          .fontColor('#F5EDE8')
          .width(26)
          .height(26)
          .borderRadius(13)
          .textAlign(TextAlign.Center)
          .backgroundColor('#66000000')
      }
      Column({ space: 5 }) {
        Text(m.name)
          .fontSize(13)
          .fontColor(TEXT_MAIN)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`${m.artistName}${m.playCount > 0 ? ` · ${this.countText(m.playCount)} 次播放` : ''}`)
          .fontSize(10)
          .fontColor(TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(formatTime(m.durationMs))
          .fontSize(9)
          .fontColor('#5A4A42')
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8, left: 2, right: 6 })
    .borderRadius(12)
    .onClick(() => {
      neteaseMv.open(m);
    })
  }

  // ─────────────────── 评论 ───────────────────

  @Builder
  commentSortChip(label: string, sort: number) {
    Text(label)
      .fontSize(11)
      .fontColor(this.commentSt.sort === sort ? '#1E1A18' : TEXT_SUB)
      .height(28)
      .padding({ left: 16, right: 16 })
      .borderRadius(14)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.commentSt.sort === sort ? settings.accent() : '#14FFFFFF')
      .onClick(() => {
        neteaseComment.setSort(sort);
      })
  }

  @Builder
  commentOverlay() {
    Column() {
      Row() {
        Text('⌄')
          .fontSize(24)
          .fontColor(TEXT_SUB)
          .width(44)
          .height(42)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            neteaseComment.close();
          })
        Blank()
        Column({ space: 2 }) {
          Text('评论')
            .fontSize(14)
            .fontColor(TEXT_MAIN)
            .letterSpacing(1)
          Text(this.commentSt.total > 0 ? `${this.countText(this.commentSt.total)} 条` : this.commentSt.title)
            .fontSize(9)
            .fontColor(TEXT_SUB)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Blank()
        Row()
          .width(44)
          .height(42)
      }
      .width('100%')

      Row({ space: 8 }) {
        this.commentSortChip('热门', CommentSort.HOT)
        this.commentSortChip('最新', CommentSort.NEW)
      }
      .width('100%')
      .margin({ top: 2, bottom: 8 })

      if (this.commentSt.loading) {
        this.onlineLoading('正在读取评论…')
      } else if (this.commentSt.comments.length === 0) {
        this.onlineEmpty(this.commentSt.message.length > 0 ? this.commentSt.message : '还没有评论')
      } else {
        List({ space: 10 }) {
          ForEach(this.commentSt.comments, (c: NeteaseComment) => {
            ListItem() {
              this.commentRow(c)
            }
          }, (c: NeteaseComment) => `cm_${c.id}_${c.isHot ? 'h' : 'n'}`)

          if (this.commentSt.hasMore) {
            ListItem() {
              Text(this.commentSt.loadingMore ? '加载中…' : '加载更多')
                .fontSize(11)
                .fontColor(settings.accent())
                .height(36)
                .width('100%')
                .textAlign(TextAlign.Center)
                .borderRadius(18)
                .backgroundColor(settings.accentSoft(0.08))
                .onClick(() => {
                  neteaseComment.loadMore();
                })
            }
          }
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: this.topInset + 8, bottom: this.bottomInset + 8 })
    .linearGradient({
      angle: 170,
      colors: [[settings.tintBackdrop(0.16), 0.0], ['#2A211E', 0.45], ['#1A1817', 1.0]]
    })
    .transition(this.routeTransition(280, 220))
  }

  @Builder
  commentRow(c: NeteaseComment) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        if (c.avatarUrl.length > 0) {
          Image(c.avatarUrl)
            .width(30)
            .height(30)
            .borderRadius(15)
            .objectFit(ImageFit.Cover)
            .draggable(false)
        } else {
          Column() {
            Text(c.nickname.length > 0 ? c.nickname.charAt(0) : '♪')
              .fontSize(12)
              .fontColor(TEXT_SUB)
          }
          .width(30)
          .height(30)
          .borderRadius(15)
          .backgroundColor('#1FFFFFFF')
          .justifyContent(FlexAlign.Center)
        }
        Column({ space: 2 }) {
          Text(c.nickname)
            .fontSize(11)
            .fontColor('#B3A199')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (c.isHot) {
            Text('热门评论')
              .fontSize(8)
              .fontColor(settings.accent())
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(`♥ ${this.countText(c.likedCount)}`)
          .fontSize(9)
          .fontColor('#5A4A42')
      }
      .width('100%')

      Text(c.content)
        .fontSize(12)
        .fontColor(TEXT_MAIN)
        .lineHeight(18)
        .maxLines(10)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      if (c.repliedContent.length > 0) {
        Text(`@${c.repliedUser}：${c.repliedContent}`)
          .fontSize(10)
          .fontColor('#8C7C74')
          .lineHeight(15)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding(8)
          .borderRadius(8)
          .backgroundColor('#0DFFFFFF')
      }

      Text(this.commentDate(c.timeMs))
        .fontSize(9)
        .fontColor('#4A403A')
        .width('100%')
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 12, right: 12 })
    .borderRadius(14)
    .backgroundColor('#0AFFFFFF')
  }

  // ─────────────────── MV 播放 ───────────────────

  @Builder
  mvOverlay() {
    Column() {
      Row() {
        Text('⌄')
          .fontSize(24)
          .fontColor(TEXT_SUB)
          .width(44)
          .height(40)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.closeMv();
          })
        Blank()
        Text('MV')
          .fontSize(14)
          .fontColor(TEXT_MAIN)
          .letterSpacing(1)
        Blank()
        Text(this.mvSt.quality)
          .fontSize(9)
          .fontColor(settings.accent())
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(9)
          .backgroundColor(settings.accentSoft(0.10))
          .margin({ right: 6 })
      }
      .width('100%')

      if (this.mvSt.loading) {
        this.onlineLoading('正在解析 MV 地址…')
      } else if (this.mvSt.url.length === 0) {
        this.onlineEmpty(this.mvSt.message.length > 0 ? this.mvSt.message : 'MV 暂时无法播放')
      } else {
        Column({ space: 12 }) {
          Video({
            src: this.mvSt.url,
            previewUri: this.mvSt.coverUrl,
            controller: this.videoCtl
          })
            .width('100%')
            .height(224)
            .autoPlay(true)
            .controls(true)
            .objectFit(ImageFit.Contain)
            .borderRadius(14)

          Text(this.mvSt.title)
            .fontSize(16)
            .fontColor(TEXT_MAIN)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Center)

          Text(`${this.mvSt.artist}${this.mvSt.durationMs > 0 ? ` · ${formatTime(this.mvSt.durationMs)}` : ''}`)
            .fontSize(10)
            .fontColor(TEXT_SUB)
            .width('100%')
            .textAlign(TextAlign.Center)

          Text('视频流来自网易云，清晰度由账号权限决定')
            .fontSize(9)
            .fontColor('#4A403A')
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Start)
        .padding({ top: 8 })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: this.topInset + 8, bottom: this.bottomInset + 8 })
    .linearGradient({
      angle: 170,
      colors: [[settings.tintBackdrop(0.18), 0.0], ['#241D1A', 0.4], ['#12100F', 1.0]]
    })
    .transition(this.routeTransition(260, 200))
  }

  private closeMv(): void {
    try {
      this.videoCtl.stop();
    } catch (e) {
      // 还没起播，忽略
    }
    neteaseMv.close();
  }

  // ─────────────────── 在线曲目操作面板 ───────────────────

  @Builder
  songActionOverlay() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .onClick(() => {
          this.closeSongActions();
        })

      Column() {
        Blank()
        Column({ space: 2 }) {
          if (this.actionSong !== null) {
            Column({ space: 4 }) {
              Text(this.actionSong.title)
                .fontSize(14)
                .fontColor(TEXT_MAIN)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(this.actionSong.artist)
                .fontSize(10)
                .fontColor(TEXT_SUB)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .width('100%')
            .padding({ bottom: 10 })

            this.songActionRow(this.actionSong !== null
              && this.favPaths.indexOf(this.actionSong.path) >= 0 ? '取消收藏' : '收藏', false, () => {
              const song = this.actionSong;
              this.closeSongActions();
              if (song !== null) {
                this.toggleFavorite(song);
              }
            })

            if (this.actionSong.isRemote()) {
              this.songActionRow(this.actionIsDownloaded() ? '已下载' : '下载', false, () => {
                this.onDownloadAction();
              })
            }

            if (this.actionSong.isRemote()) {
              this.songActionRow('查看评论', false, () => {
                const song = this.actionSong;
                this.closeSongActions();
                if (song !== null) {
                  neteaseComment.open(song);
                }
              })
            }

            if (this.actionSong.artistId > 0) {
              this.songActionRow('歌手主页', false, () => {
                const song = this.actionSong;
                this.closeSongActions();
                if (song !== null) {
                  this.openArtist(song.artistId, song.artist);
                }
              })
            }

            this.songActionRow('加入歌单', false, () => {
              const song = this.actionSong;
              this.closeSongActions();
              if (song !== null) {
                this.pickerSong = song.isRemote() ? song : null;
                this.pickerPath = song.path;
              }
            })
          }
          this.songActionRow('取消', true, () => {
            this.closeSongActions();
          })
        }
        .width('100%')
        .padding({ top: 14, bottom: this.bottomInset + 10, left: 16, right: 16 })
        .borderRadius({ topLeft: 22, topRight: 22 })
        .backgroundColor('#241D1A')
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .transition(this.sheetTransition(240, 200))
  }

  @Builder
  songActionRow(label: string, danger: boolean, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(danger ? '#FF6B6B' : TEXT_MAIN)
      .height(46)
      .width('100%')
      .textAlign(TextAlign.Center)
      .borderRadius(12)
      .backgroundColor('#0DFFFFFF')
      .onClick(action)
  }

  private openArtist(artistId: number, artistName: string): void {
    if (artistId <= 0) {
      return;
    }
    this.briefOpen = false;
    const name = artistName.indexOf(' / ') > 0 ? artistName.substring(0, artistName.indexOf(' / ')) : artistName;
    neteaseArtist.open(artistId, name);
  }

  private actionIsDownloaded(): boolean {
    return this.actionSong !== null && downloader.isDownloaded(this.actionSong.path);
  }

  private onDownloadAction(): void {
    const song = this.actionSong;
    if (song === null) {
      return;
    }
    if (downloader.isDownloaded(song.path)) {
      this.closeSongActions();
      this.viewMode = 8;
      return;
    }
    this.closeSongActions();
    downloader.enqueue(song);
  }

  private closeSongActions(): void {
    this.actionOpen = false;
    this.actionSong = null;
  }

  /** 评论时间：只显示到天，够用又不占宽 */
  private commentDate(ms: number): string {
    if (ms <= 0) {
      return '';
    }
    const d = new Date(ms);
    const m = d.getMonth() + 1;
    const day = d.getDate();
    return `${d.getFullYear()}-${m < 10 ? `0${m}` : m}-${day < 10 ? `0${day}` : day}`;
  }

  // ─────────────────── 登录（扫码 / Cookie） ───────────────────

  @Builder
  loginOverlay() {
    Column() {
      Row() {
        Text('⌄')
          .fontSize(24)
          .fontColor(TEXT_SUB)
          .width(44)
          .height(44)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.closeLogin();
          })
        Blank()
        Text('网易云账号')
          .fontSize(14)
          .fontColor(TEXT_MAIN)
          .letterSpacing(1)
        Blank()
        Row()
          .width(44)
          .height(44)
      }
      .width('100%')

      Scroll() {
        Column({ space: 14 }) {
          if (this.auth.loggedIn) {
            // 已登录
            Column({ space: 12 }) {
              if (this.auth.avatarUrl.length > 0) {
                Image(this.auth.avatarUrl)
                  .width(72)
                  .height(72)
                  .borderRadius(36)
                  .objectFit(ImageFit.Cover)
                  .draggable(false)
              } else {
                Column()
                  .width(72)
                  .height(72)
                  .borderRadius(36)
                  .backgroundColor('#1FFFFFFF')
              }
              Text(this.auth.nickname)
                .fontSize(16)
                .fontColor(TEXT_MAIN)
              Text(this.auth.vipLabel())
                .fontSize(11)
                .fontColor(settings.accent())
              Text(`UID ${this.auth.userId}`)
                .fontSize(10)
                .fontColor('#5A4A42')

              Text('退出登录')
                .fontSize(12)
                .fontColor('#FF6B6B')
                .height(36)
                .padding({ left: 22, right: 22 })
                .borderRadius(18)
                .textAlign(TextAlign.Center)
                .backgroundColor('#1AFF6B6B')
                .margin({ top: 6 })
                .onClick(() => {
                  this.confirmLogout();
                })
            }
            .width('100%')
            .padding({ top: 30, bottom: 30 })
            .borderRadius(20)
            .backgroundColor('#0DFFFFFF')
          } else {
            // 未登录：两种方式
            Row({ space: 6 }) {
              this.loginTabChip('扫码登录', 0)
              this.loginTabChip('Cookie 导入', 1)
            }
            .width('100%')

            if (this.loginTab === 0) {
              this.qrPanel()
            } else {
              this.cookiePanel()
            }
          }

          if (this.auth.message.length > 0) {
            Text(this.auth.message)
              .fontSize(11)
              .fontColor(this.auth.message.indexOf('失败') >= 0 || this.auth.message.indexOf('无效') >= 0
                ? '#FF6B6B' : TEXT_SUB)
              .textAlign(TextAlign.Center)
              .width('100%')
          }

          Text('凭据只保存在本机，用于读取你自己的歌单与会员权限')
            .fontSize(9)
            .fontColor('#4A403A')
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ top: 4, bottom: 20 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: this.topInset + 10, bottom: this.bottomInset + 10 })
    .linearGradient({
      angle: 170,
      colors: [[settings.tintBackdrop(0.16), 0.0], ['#2A211E', 0.45], ['#1A1817', 1.0]]
    })
    .transition(this.sheetTransition(280, 220))
  }

  @Builder
  loginTabChip(label: string, tab: number) {
    Text(label)
      .fontSize(11)
      .fontColor(this.loginTab === tab ? '#1E1A18' : TEXT_SUB)
      .height(32)
      .layoutWeight(1)
      .borderRadius(16)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.loginTab === tab ? settings.accent() : '#14FFFFFF')
      .onClick(() => {
        this.loginTab = tab;
        this.auth.message = '';
        if (tab !== 0) {
          neteaseAuth.stopQrLogin();
        } else if (!this.auth.loggedIn && this.auth.qrPhase !== QrPhase.WAITING
          && this.auth.qrPhase !== QrPhase.SCANNED) {
          this.probeFingerprint(0);
        }
      })
  }

  @Builder
  qrPanel() {
    Column({ space: 14 }) {
      if (this.auth.qrPhase === QrPhase.LOADING) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color(settings.accent())
          Text(this.fpReady ? '正在申请二维码…' : '正在准备登录环境…')
            .fontSize(11)
            .fontColor(TEXT_SUB)
        }
        .width(220)
        .height(220)
        .justifyContent(FlexAlign.Center)
      } else if (this.auth.qrPhase === QrPhase.EXPIRED || this.auth.qrPhase === QrPhase.ERROR) {
        Column({ space: 12 }) {
          Text(this.auth.qrMessage.length > 0 ? this.auth.qrMessage : '二维码不可用')
            .fontSize(11)
            .fontColor(TEXT_SUB)
            .textAlign(TextAlign.Center)
          Text('刷新二维码')
            .fontSize(11)
            .fontColor('#1E1A18')
            .height(32)
            .padding({ left: 18, right: 18 })
            .borderRadius(16)
            .textAlign(TextAlign.Center)
            .backgroundColor(settings.accent())
            .onClick(() => {
              neteaseAuth.refreshQr();
            })
        }
        .width(220)
        .height(220)
        .justifyContent(FlexAlign.Center)
      } else if (this.auth.qrKey.length > 0) {
        Stack() {
          Column()
            .width(220)
            .height(220)
            .borderRadius(16)
            .backgroundColor('#FFFFFF')
          QRCode(this.qrContentSafe())
            .width(196)
            .height(196)
            .color('#1A1513')
            .backgroundColor('#FFFFFF')
        }
        .width(220)
        .height(220)

        if (this.auth.qrPhase === QrPhase.SCANNED) {
          Text('已扫码，请在手机上确认')
            .fontSize(12)
            .fontColor(settings.accent())
        } else {
          Text('用网易云音乐 App 扫描二维码')
            .fontSize(12)
            .fontColor(TEXT_MAIN)
        }
      } else {
        Column()
          .width(220)
          .height(220)
      }

      Text('扫码没反应？可切到「Cookie 导入」，从浏览器复制凭据')
        .fontSize(10)
        .fontColor('#5A4A42')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ top: 24, bottom: 24 })
    .borderRadius(20)
    .backgroundColor('#0DFFFFFF')
  }

  @Builder
  cookiePanel() {
    Column({ space: 12 }) {
      Text('从浏览器或抓包工具里复制 music.163.com 的 Cookie')
        .fontSize(11)
        .fontColor(TEXT_SUB)
        .width('100%')
      TextArea({ text: this.auth.cookieDraft, placeholder: 'MUSIC_U=xxxx; __csrf=yyyy' })
        .placeholderColor('#5A4A42')
        .fontSize(11)
        .fontColor(TEXT_MAIN)
        .height(120)
        .width('100%')
        .borderRadius(12)
        .backgroundColor('#14FFFFFF')
        .caretColor(settings.accent())
        .onChange((value: string) => {
          this.auth.cookieDraft = value;
        })

      Row({ space: 8 }) {
        Text('读剪贴板')
          .fontSize(11)
          .fontColor(TEXT_SUB)
          .height(34)
          .layoutWeight(1)
          .borderRadius(17)
          .textAlign(TextAlign.Center)
          .backgroundColor('#14FFFFFF')
          .onClick(() => {
            this.pasteCookie();
          })
        Text('登录')
          .fontSize(11)
          .fontColor('#1E1A18')
          .height(34)
          .layoutWeight(1)
          .borderRadius(17)
          .textAlign(TextAlign.Center)
          .backgroundColor(settings.accent())
          .enabled(!this.auth.busy)
          .onClick(() => {
            this.doCookieLogin();
          })
      }
      .width('100%')

      Text('只填 MUSIC_U 的值也可以；导入后会立刻校验一次')
        .fontSize(9)
        .fontColor('#4A403A')
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .borderRadius(20)
    .backgroundColor('#0DFFFFFF')
  }

  private qrContentSafe(): string {
    const content = neteaseAuth.qrContent();
    return content.length > 0 ? content : 'https://music.163.com';
  }

  // ─────────────── 风控指纹（ydDeviceToken） ───────────────

  private resetFingerprint(): void {
    this.fpToken = '';
    this.fpCookieRaw = '';
    this.fpDone = false;
    this.fpStarted = false;
    this.fpReady = false;
    if (this.fpTimer >= 0) {
      clearTimeout(this.fpTimer);
      this.fpTimer = -1;
    }
    // 不主动清 cookie：sDeviceId 的连续性本身就是风控要看的东西，
    // 每次清掉反而会让服务端认为这是一台陌生设备。
  }

  /** 轮询页面是否已经具备 createNEFingerprint */
  private async probeFingerprint(attempt: number): Promise<void> {
    if (this.fpDone || this.fpStarted || !this.showLogin) {
      return;
    }
    if (attempt > 40) {
      let state = '';
      try {
        state = await this.fpCtl.runJavaScript(
          "(function(){try{return JSON.stringify({href: location.href, keys: Object.keys(window).filter(function(k){ return k.indexOf('NE') >= 0 || k.indexOf('finger') >= 0; })});}catch(e){return String(e);}})()");
      } catch (e) {
        state = 'probe failed';
      }
      Logger.w(`网页没有提供 createNEFingerprint，退回无令牌扫码；${state}`);
      this.finishFingerprint('');
      return;
    }
    let ready = false;
    try {
      const raw = await this.fpCtl.runJavaScript(
        "(function(){try{return typeof createNEFingerprint === 'function' ? '1' : '0';}catch(e){return '0';}})()");
      ready = raw.indexOf('1') >= 0;
    } catch (e) {
      // 页面还没加载完，下一轮再试
    }
    if (ready) {
      Logger.i('网页已就绪，开始申请风控指纹');
      this.requestFingerprint();
      return;
    }
    this.fpTimer = setTimeout(() => {
      this.probeFingerprint(attempt + 1);
    }, 400);
  }

  /** 让网页去申请指纹，结果写进全局变量，随后轮询读取 */
  private async requestFingerprint(): Promise<void> {
    this.fpStarted = true;
    try {
      await this.fpCtl.runJavaScript(
        '(function(){' +
        'window.__memiYdToken = "";' +
        'window.__memiYdError = "";' +
        'try {' +
        '  var inst = createNEFingerprint({appId: "9d0ef7e0905d422cba1ecf7e73d77e67", timeout: 6000});' +
        '  inst.getToken().then(function(r){ window.__memiYdToken = (r && r.token) || ""; })' +
        '    .catch(function(e){ window.__memiYdError = String(e); });' +
        '  return "started";' +
        '} catch (e) { window.__memiYdError = String(e); return "error"; }' +
        '})()');
    } catch (e) {
      Logger.w(`启动指纹申请失败 ${(e as Error).message}`);
    }
    this.fpTimer = setTimeout(() => {
      this.pollFingerprint(0);
    }, 400);
  }

  private async pollFingerprint(attempt: number): Promise<void> {
    if (this.fpDone || !this.showLogin) {
      return;
    }
    if (attempt > 30) {
      Logger.w('读取风控指纹超时，按无令牌继续');
      this.finishFingerprint('');
      return;
    }
    let token = '';
    try {
      const raw = await this.fpCtl.runJavaScript('(window.__memiYdToken || "")');
      token = this.stripJsString(raw);
    } catch (e) {
      // 忽略，继续等
    }
    if (token.length > 0) {
      this.finishFingerprint(token);
      return;
    }
    this.fpTimer = setTimeout(() => {
      this.pollFingerprint(attempt + 1);
    }, 400);
  }

  private stripJsString(raw: string): string {
    const t = raw.trim();
    if (t.length === 0 || t === 'null' || t === 'undefined') {
      return '';
    }
    if (t.charAt(0) === '"' && t.charAt(t.length - 1) === '"') {
      return t.substring(1, t.length - 1);
    }
    return t;
  }

  /** 指纹拿到了（或确认拿不到）：读出 cookie 后正式开始出码 */
  private finishFingerprint(token: string): void {
    if (this.fpDone) {
      return;
    }
    this.fpDone = true;
    this.fpToken = token;
    try {
      this.fpCookieRaw = webview.WebCookieManager.fetchCookieSync('https://music.163.com');
    } catch (e) {
      this.fpCookieRaw = '';
    }
    this.fpReady = true;
    Logger.i(`风控指纹 ${token.length > 0 ? `已获取 len=${token.length}` : '为空'}，`
      + `网页 cookie len=${this.fpCookieRaw.length}`);
    if (!this.auth.loggedIn) {
      neteaseAuth.startQrLogin(this.fpToken, this.fpCookieRaw);
    }
  }

  private openLogin(): void {
    this.auth.message = '';
    this.auth.qrMessage = '';
    this.loginTab = 0;
    this.showLogin = true;
    if (this.auth.loggedIn) {
      return;
    }
    this.resetFingerprint();
    // WebView 要等这一帧挂载完才存在，probe 里会自己重试
    this.probeFingerprint(0);
  }

  private closeLogin(): void {
    this.showLogin = false;
    neteaseAuth.stopQrLogin();
    if (this.fpTimer >= 0) {
      clearTimeout(this.fpTimer);
      this.fpTimer = -1;
    }
  }

  private async pasteCookie(): Promise<void> {
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      const text = data.getPrimaryText();
      if (text.length > 0) {
        this.auth.cookieDraft = text;
        this.auth.message = '已从剪贴板读取';
      } else {
        this.auth.message = '剪贴板里没有文本';
      }
    } catch (e) {
      this.auth.message = '读剪贴板失败，请手动长按粘贴';
    }
  }

  private async doCookieLogin(): Promise<void> {
    const ok = await neteaseAuth.loginWithCookie(this.auth.cookieDraft);
    if (ok) {
      this.showLogin = false;
      await netease.resetForAccount();
      this.lib.message = `已登录网易云：${this.auth.nickname}`;
    }
  }

  private confirmLogout(): void {
    const options: AlertDialogParamWithOptions = {
      title: '退出登录',
      message: '退出后会员曲目与高音质将不可用',
      buttons: [
        {
          value: '退出',
          fontColor: '#FF6B6B',
          action: () => {
            this.doLogout();
          }
        },
        {
          value: '取消',
          action: () => {
          }
        }
      ]
    };
    this.getUIContext().showAlertDialog(options);
  }

  private async doLogout(): Promise<void> {
    await neteaseAuth.logout();
    this.showLogin = false;
    netease.clearUrlCache();
    await netease.resetForAccount();
    this.lib.message = '已退出网易云';
  }

  @Builder
  qualityChip(label: string, quality: number) {
    Text(label)
      .fontSize(11)
      .fontColor(this.st.onlineQuality === quality ? '#241C18' : TEXT_SUB)
      .height(30)
      .layoutWeight(1)
      .borderRadius(15)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.st.onlineQuality === quality ? settings.accent() : '#14FFFFFF')
      .onClick(() => {
        settings.setOnlineQuality(quality);
        netease.clearUrlCache();
      })
  }

  private onlineVisibleCount(): number {
    if (this.online.tab === 0) {
      return this.online.songs.length;
    }
    return this.online.tab === 1 ? this.online.playlistResults.length : this.online.albumResults.length;
  }

  private onlinePlaylistSub(p: NeteasePlaylist, isPlaylist: boolean): string {
    const parts: string[] = [];
    if (p.creator.length > 0) {
      parts.push(p.creator);
    }
    if (isPlaylist) {
      parts.push(`${this.countText(p.playCount)} 次播放`);
      if (p.trackCount > 0) {
        parts.push(`${p.trackCount} 首`);
      }
    }
    return parts.join(' · ');
  }

  /** 播放量按中文习惯缩写 */
  private countText(n: number): string {
    if (n >= 100000000) {
      return `${(n / 100000000).toFixed(1)}亿`;
    }
    if (n >= 10000) {
      return `${(n / 10000).toFixed(1)}万`;
    }
    return `${n}`;
  }

  /**
   * 在线曲目长按菜单。
   * 用自定义面板而不是 AlertDialog：按钮数会随「是否有歌手 ID」变化，
   * AlertDialog 的按钮布局在 4 个以上会挤在一起。
   */
  private showOnlineMenu(song: Song): void {
    this.actionSong = song;
    this.actionOpen = true;
  }

  @Builder
  statRow(i: number) {
    if (i < this.statsState.top.length) {
      Row({ space: 10 }) {
        Text(`${i + 1}`)
          .fontSize(11)
          .fontColor(i < 3 ? settings.accent() : '#5A4A42')
          .width(20)
          .textAlign(TextAlign.Center)
        Column({ space: 3 }) {
          Text(this.statTitle(i))
            .fontSize(13)
            .fontColor(TEXT_MAIN)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.statArtist(i))
            .fontSize(10)
            .fontColor(TEXT_SUB)
            .maxLines(1)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(`${this.statCount(i)}`)
          .fontSize(12)
          .fontColor(settings.accent())
      }
      .width('100%')
      .padding({ top: 9, bottom: 9, left: 14, right: 14 })
      .onClick(() => {
        this.playStatsSong(this.statItem(i));
      })
    }
  }

  private statItem(i: number): StatsTopItem {
    const arr = this.statsState.top;
    return i < arr.length ? arr[i] : new StatsTopItem();
  }

  private statTitle(i: number): string {
    const item = this.statItem(i);
    return item.title;
  }

  private statArtist(i: number): string {
    const item = this.statItem(i);
    return item.artist.length > 0 ? item.artist : '未知艺术家';
  }

  private statCount(i: number): number {
    const item = this.statItem(i);
    return item.count;
  }

  @Builder
  metricCard(label: string, value: string) {
    Column({ space: 6 }) {
      Text(value)
        .fontSize(20)
        .fontColor(settings.accent())
        .fontWeight(FontWeight.Medium)
        .width('100%')
      Text(label)
        .fontSize(10)
        .fontColor(TEXT_SUB)
        .width('100%')
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .borderRadius(16)
    .backgroundColor('#0DFFFFFF')
  }

  @Builder
  recentView() {
    Column() {
      Row() {
        Text(`最近播放 ${this.recentSongs.length} 首`)
          .fontSize(11)
          .fontColor(TEXT_SUB)
        Blank()
        Text('刷新')
          .fontSize(11)
          .fontColor(settings.accent())
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(12)
          .backgroundColor(settings.accentSoft(0.10))
          .onClick(() => {
            this.refreshRecent();
          })
      }
      .width('100%')
      .margin({ top: 8, bottom: 6 })

      if (this.recentSongs.length === 0) {
        Column({ space: 8 }) {
          Text('还没有播放记录')
            .fontSize(13)
            .fontColor(TEXT_SUB)
          Text('放几首歌之后这里会按时间倒序出现')
            .fontSize(10)
            .fontColor('#5A4A42')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        this.songList(this.recentSongs)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  favoriteView() {
    Column() {
      Row() {
        Text(`收藏 ${this.favoriteSongs.length} 首`)
          .fontSize(11)
          .fontColor(TEXT_SUB)
        Blank()
        Text('播放全部')
          .fontSize(11)
          .fontColor('#1E1A18')
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(12)
          .backgroundColor(settings.accent())
          .onClick(() => {
            if (this.favoriteSongs.length > 0) {
              playback.setQueue(this.favoriteSongs);
              playback.playIndex(0);
            }
          })
      }
      .width('100%')
      .margin({ top: 8, bottom: 6 })

      if (this.favoriteSongs.length === 0) {
        Column({ space: 8 }) {
          Text('还没有收藏')
            .fontSize(13)
            .fontColor(TEXT_SUB)
          Text('长按任意歌曲，选「收藏」')
            .fontSize(10)
            .fontColor('#5A4A42')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        this.songList(this.favoriteSongs, 2)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  groupList() {
    List({ space: 2 }) {
      ForEach(this.viewMode === 1 ? this.lib.albumGroups : this.lib.artistGroups,
        (group: GroupItem, index: number) => {
          ListItem() {
            this.libGroupRow(group, () => {
              this.groupKey = group.name;
            })
          }
        }, (group: GroupItem) => `${this.viewMode}_${group.name}`)
    }
    .layoutWeight(1)
    .width('100%')
    .contentEndOffset(this.chromeInset())
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .margin({ top: 4 })
  }

  /** 收藏里按专辑/艺术家分组，复用 libGroupRow */
  @Builder
  favGroupList() {
    List({ space: 2 }) {
      ForEach(this.favGroups(this.favTab === 1),
        (group: GroupItem) => {
          ListItem() {
            this.libGroupRow(group, () => {
              this.favGroupKey = group.name;
            })
          }
        }, (group: GroupItem) => `fav_${this.favTab}_${group.name}`)
    }
    .layoutWeight(1)
    .width('100%')
    .contentEndOffset(this.chromeInset())
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .margin({ top: 4 })
  }

  @Builder
  libGroupRow(group: GroupItem, onTap: () => void) {
    Row({ space: 12 }) {
      Stack() {
        if (this.st.showThumbs && this.thumbs.version >= 0 && cover.thumbOf(group.samplePath) !== null) {
          Image(cover.thumbOf(group.samplePath) as image.PixelMap)
            .width(48)
            .height(48)
            .borderRadius(10)
            .objectFit(ImageFit.Cover)
            .draggable(false)
        } else if (group.coverUrl.length > 0) {
          Image(group.coverUrl)
            .width(48)
            .height(48)
            .borderRadius(10)
            .objectFit(ImageFit.Cover)
            .draggable(false)
        } else {
          Column()
            .width(48)
            .height(48)
            .borderRadius(10)
            .backgroundColor('#14FFFFFF')
        }
      }
      .width(48)
      .height(48)

      Column({ space: 4 }) {
        Text(group.name)
          .fontSize(14)
          .fontColor(TEXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(group.subtitle.length > 0 ? `${group.count} 首 · ${group.subtitle}` : `${group.count} 首`)
          .fontSize(10)
          .fontColor(TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(18)
        .fontColor('#4D423C')
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 6, right: 6 })
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  groupSongsView() {
    Column() {
      Row({ space: 6 }) {
        Text(`‹ ${this.viewMode === 1 ? '全部专辑' : '全部艺术家'}`)
          .fontSize(11)
          .fontColor(settings.accent())
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(12)
          .backgroundColor(settings.accentSoft(0.10))
          .onClick(() => {
            this.groupKey = '';
          })
      }
      .width('100%')
      .margin({ top: 8, bottom: 4 })

      this.groupDetailHeader()

      this.songList(library.songsOfGroup(this.viewMode === 1, this.groupKey))
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 专辑 / 艺术家的详情头：封面 + 名称 + 统计 + 播放全部 */
  @Builder
  groupDetailHeader() {
    Row({ space: 14 }) {
      Stack() {
        if (this.st.showThumbs && this.thumbs.version >= 0 && cover.thumbOf(this.groupSamplePath()) !== null) {
          Image(cover.thumbOf(this.groupSamplePath()) as image.PixelMap)
            .width(84)
            .height(84)
            .borderRadius(this.viewMode === 1 ? 12 : 42)
            .objectFit(ImageFit.Cover)
            .draggable(false)
        } else {
          Column() {
            Text(this.groupInitial())
              .fontSize(28)
              .fontColor('#4D423C')
          }
          .width(84)
          .height(84)
          .borderRadius(this.viewMode === 1 ? 12 : 42)
          .backgroundColor('#1FFFFFFF')
          .justifyContent(FlexAlign.Center)
        }
      }
      .width(84)
      .height(84)

      Column({ space: 6 }) {
        Text(this.groupKey)
          .fontSize(16)
          .fontColor(TEXT_MAIN)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.groupStats())
          .fontSize(10)
          .fontColor(TEXT_SUB)
          .width('100%')
        Text('播放全部')
          .fontSize(11)
          .fontColor('#1E1A18')
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .borderRadius(12)
          .backgroundColor(settings.accent())
          .onClick(() => {
            this.playGroup();
          })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .margin({ bottom: 8 })
  }

  @Builder
  statusLine() {
    Column({ space: 2 }) {
      if (this.tab === 2 && this.lib.message.length > 0) {
        Text(this.lib.message)
          .fontSize(10)
          .fontColor(TEXT_SUB)
      }
      if (this.tab === 2 && this.lib.progressText.length > 0) {
        Text(this.lib.progressText)
          .fontSize(10)
          .fontColor(settings.accent())
      }
      if (this.player.errorMsg.length > 0) {
        Text(this.player.errorMsg)
          .fontSize(10)
          .fontColor('#FF6B6B')
          .maxLines(2)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: 10, bottom: 4 })
  }

  @Builder
  emptyState() {
    Column({ space: 10 }) {
      Text('♫')
        .fontSize(48)
        .fontColor('#40352F')
      Text('还没有曲库')
        .fontSize(14)
        .fontColor(TEXT_SUB)
      Text('用「导入文件」挑几首歌\n或先用「示例曲库」造几首测试曲')
        .fontSize(11)
        .fontColor('#6B5D56')
        .textAlign(TextAlign.Center)
        .lineHeight(18)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  noResultState() {
    Column({ space: 8 }) {
      Text('没有匹配的歌曲')
        .fontSize(13)
        .fontColor(TEXT_SUB)
      Text(`曲库里共 ${this.lib.songs.length} 首`)
        .fontSize(10)
        .fontColor('#5A4A42')
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  songList(songs: Song[], listCtx: number = 0) {
    List({ space: 2 }) {
      ForEach(songs, (song: Song, index: number) => {
        ListItem() {
          this.songRow(song, index, listCtx, songs)
        }
      }, (song: Song) => `sl_${song.path}`)
    }
    .layoutWeight(1)
    .width('100%')
    .contentEndOffset(this.chromeInset())
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .margin({ top: 4 })
  }

  @Builder
  songRow(song: Song, index: number, listCtx: number, from: Song[]) {
    Row({ space: 10 }) {
      Row()
        .width(settings.ui(3))
        .height(settings.ui(20))
        .borderRadius(2)
        .backgroundColor(this.isCurrent(song) ? settings.accent() : '#00000000')

      Stack() {
        if (this.st.showThumbs && this.thumbs.version >= 0 && cover.thumbOf(song.path) !== null) {
          Image(cover.thumbOf(song.path) as image.PixelMap)
            .width(settings.ui(44))
            .height(settings.ui(44))
            .borderRadius(9)
            .objectFit(ImageFit.Cover)
            .draggable(false)
        } else if (song.coverUrl.length > 0) {
          // 在线曲目没有本地缩略图，直接把网络封面交给 Image
          Image(song.coverUrl)
            .width(settings.ui(44))
            .height(settings.ui(44))
            .borderRadius(9)
            .objectFit(ImageFit.Cover)
            .draggable(false)
        } else {
          Column({ space: 0 }) {
            Text(`${index + 1}`)
              .fontSize(settings.ui(11))
              .fontColor(this.isCurrent(song) ? settings.accent() : '#5A4A42')
          }
          .width(settings.ui(44))
          .height(settings.ui(44))
          .borderRadius(9)
          .backgroundColor('#14FFFFFF')
          .justifyContent(FlexAlign.Center)
        }
      }
      .width(settings.ui(44))
      .height(settings.ui(44))

      Column({ space: 3 }) {
        Text(song.title)
          .fontSize(settings.ui(14))
          .fontColor(this.isCurrent(song) ? settings.accent() : TEXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.subtitle(song))
          .fontSize(settings.ui(10))
          .fontColor(TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.favPaths.indexOf(song.path) >= 0) {
        Image($r('app.media.ic_heart'))
          .width(settings.ui(12))
          .height(settings.ui(12))
          .fillColor(settings.accent())
          .margin({ right: 5 })
          .draggable(false)
      }

      Text(formatTime(song.durationMs))
        .fontSize(settings.ui(10))
        .fontColor(TEXT_SUB)
    }
    .width('100%')
    .padding({ top: settings.ui(10), bottom: settings.ui(10), left: 4, right: 8 })
    .borderRadius(12)
    .backgroundColor(this.isCurrent(song) ? settings.accentSoft(0.08) : '#00000000')
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.99 })
    .onClick(() => {
      // 一定要用「当前这个列表」当队列。
      // 早先这里按 viewMode 反推，结果歌单/最近/收藏里点歌会拿到空数组，
      // 队列被清空、歌不播，后面的自动连播也跟着失效。
      playback.playSong(song, from);
    })
    .gesture(LongPressGesture({ repeat: false })
      .onAction(() => {
        if (listCtx === 1) {
          this.confirmRemoveFromPlaylist(song);
        } else if (listCtx === 2) {
          this.showFavoriteMenu(song);
        } else {
          this.showSongMenu(song);
        }
      }))
  }

  /** 迷你播放器：封面 + 曲名/歌手 + 播放暂停，点整条进播放页 */
  @Builder
  miniPlayer() {
    Row({ space: 12 }) {
      Stack() {
        // 读一次 thumbs.version：缩略图是后台解出来的，解完要能刷新
        if (!this.player.currentPath.startsWith('netease://') && this.st.showThumbs
          && this.thumbs.version >= 0 && cover.thumbOf(this.player.currentPath) !== null) {
          Image(cover.thumbOf(this.player.currentPath) as image.PixelMap)
            .width(46)
            .height(46)
            .borderRadius(10)
            .objectFit(ImageFit.Cover)
            .draggable(false)
        } else if (this.player.coverUrl.length > 0) {
          Image(this.player.coverUrl)
            .width(46)
            .height(46)
            .borderRadius(10)
            .objectFit(ImageFit.Cover)
            .draggable(false)
        } else {
          Column()
            .width(46)
            .height(46)
            .borderRadius(10)
            .backgroundColor('#1FFFFFFF')
        }
      }
      .width(46)
      .height(46)

      Column({ space: 3 }) {
        Text(this.player.title.length > 0 ? this.player.title : '未在播放')
          .fontSize(15)
          .fontColor(TEXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.miniSubtitle())
          .fontSize(11)
          .fontColor(TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Stack() {
        if (this.player.isPlaying) {
          Image($r('app.media.ic_pause'))
            .width(20)
            .height(20)
            .fillColor(TEXT_MAIN)
            .draggable(false)
            .transition(TransitionEffect.scale({ x: 0.72, y: 0.72 })
              .animation({ duration: settings.motionMs(300), curve: curves.springMotion(0.32, 0.72) })
              .combine(TransitionEffect.OPACITY.animation({ duration: settings.motionMs(110) })))
        } else {
          Image($r('app.media.ic_play'))
            .width(20)
            .height(20)
            .fillColor(TEXT_MAIN)
            .draggable(false)
            .transition(TransitionEffect.scale({ x: 0.72, y: 0.72 })
              .animation({ duration: settings.motionMs(300), curve: curves.springMotion(0.32, 0.72) })
              .combine(TransitionEffect.OPACITY.animation({ duration: settings.motionMs(110) })))
        }
      }
      .width(24)
      .height(24)
      .margin({ right: 8 })
      .onClick(() => {
          audioPlayer.toggle();
        })
    }
    .width('100%')
    .height(62)
    .padding({ left: 9, right: 9 })
    .borderRadius(20)
    .backgroundColor(this.chromeBg())
    .backdropBlur(this.st.chromeGlass / 100 * 30)
    .borderWidth(1)
    .borderColor('#1FFFFFFF')
    .onClick(() => {
      this.openPlayer();
    })
  }

  /** 底部胶囊页签栏 */
  @Builder
  tabBar() {
    Row() {
      this.tabItem('首页', 0, $r('app.media.ic_tab_home'))
      this.tabItem('探索', 1, $r('app.media.ic_tab_search'))
      this.tabItem('媒体库', 2, $r('app.media.ic_tab_library'))
      this.tabItem('设置', 3, $r('app.media.ic_tab_settings'))
    }
    .width('100%')
    .height(64)
    .padding({ left: 6, right: 6 })
    .borderRadius(26)
    .backgroundColor(this.chromeBg())
    .backdropBlur(this.st.chromeGlass / 100 * 30)
    .borderWidth(1)
    .borderColor('#26FFFFFF')
    .shadow({ radius: 20, color: '#66000000', offsetX: 0, offsetY: 8 })
  }

  @Builder
  tabItem(label: string, index: number, icon: Resource) {
    Column({ space: 4 }) {
      Image(icon)
        .width(22)
        .height(22)
        .fillColor(this.tab === index ? TEXT_MAIN : '#8E8079')
        .draggable(false)
      Text(label)
        .fontSize(10)
        .fontColor(this.tab === index ? TEXT_MAIN : '#8E8079')
    }
    .layoutWeight(1)
    .height(52)
    .justifyContent(FlexAlign.Center)
    .borderRadius(22)
    .backgroundColor(this.tab === index ? '#22FFFFFF' : '#00000000')
    .onClick(() => {
      this.jumpTab(index);
    })
  }

  /** 宽屏左侧导航栏：底部页签的竖排版，把纵向空间让给内容 */
  @Builder
  railBar() {
    Column({ space: 6 }) {
      this.railItem('首页', 0, $r('app.media.ic_tab_home'))
      this.railItem('探索', 1, $r('app.media.ic_tab_search'))
      this.railItem('媒体库', 2, $r('app.media.ic_tab_library'))
      this.railItem('设置', 3, $r('app.media.ic_tab_settings'))
    }
    .width(this.railWidth)
    .height('100%')
    .padding({
      left: 10,
      right: 10,
      top: this.topInset + 16,
      bottom: this.bottomInset + 16
    })
  }

  @Builder
  railItem(label: string, index: number, icon: Resource) {
    Column({ space: 5 }) {
      Image(icon)
        .width(24)
        .height(24)
        .fillColor(this.tab === index ? TEXT_MAIN : '#8E8079')
        .draggable(false)
      Text(label)
        .fontSize(10)
        .fontColor(this.tab === index ? TEXT_MAIN : '#8E8079')
    }
    .width('100%')
    .height(60)
    .justifyContent(FlexAlign.Center)
    .borderRadius(18)
    .backgroundColor(this.tab === index ? '#22FFFFFF' : '#00000000')
    .onClick(() => {
      this.jumpTab(index);
    })
  }

  /** 页签点击：当前页签再点回顶层，否则切换并补一次懒加载 */
  private jumpTab(index: number): void {
    if (this.tab === index) {
      // 媒体库回到「歌曲」，设置回到首页
      if (index === 2 && this.viewMode !== 0) {
        this.viewMode = 0;
        this.groupKey = '';
        this.playlistId = '';
      } else if (index === 3 && this.settingsPage.length > 0) {
        this.settingsPage = '';
      }
      return;
    }
    // 详情页在内容区里优先于页签显示，切页签前必须收掉，
    // 否则歌单 / 专辑会一直压在新页签上面
    netease.closeDetail();
    this.switchTab(index);
    if (index === 0) {
      netease.loadHome();
    }
    if (index === 1) {
      netease.ensureExplore();
    }
    if (index === 3) {
      this.settingsPage = '';
    }
    if (index === 2) {
      this.onModeChanged(this.viewMode);
    }
  }

  /** 歌词页：顶部小封面 + 大字歌词 + 底部迷你控制 */
  @Builder
  lyricsOverlay() {
    Stack() {
      this.playerBackdropLayer()

      Column() {
        Row({ space: 10 }) {
          this.topIcon($r('app.media.ic_nav_back'), '#F2E8E3', () => {
            this.showLyrics = false;
          })

          Stack() {
            if (this.covers.cover !== null) {
              Image(this.covers.cover as image.PixelMap)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .draggable(false)
            } else if (this.remoteCoverUrl().length > 0) {
              Image(this.remoteCoverUrl())
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .draggable(false)
            } else {
              Column()
                .width('100%')
                .height('100%')
                .backgroundColor('#1FFFFFFF')
            }
          }
          .width(34)
          .height(34)
          .borderRadius(8)
          .clip(true)

          Column({ space: 2 }) {
            Text(this.player.title.length > 0 ? this.player.title : '未在播放')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.currentArtist())
              .fontSize(10)
              .fontColor('#C9BBB4')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Stack() {
            this.heartIcon()
          }
          .width(44)
          .height(44)
          .onClick(() => {
            const song = playback.currentSong();
            if (song !== null) {
              this.toggleFavorite(song);
            }
          })
          this.moreButton('#F2E8E3', () => {
            const song = playback.currentSong();
            if (song !== null) {
              this.showSongMenu(song);
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.lyrics.hasLyric) {
          Stack() {
            List({ scroller: this.scroller }) {
              ForEach(this.lyrics.lines, (line: LyricLine, index: number) => {
                ListItem() {
                  Column({ space: 6 }) {
                    if (index === this.lyrics.currentIndex) {
                      Text() {
                        ForEach(cellsForLine(line, lyric.adjust(this.renderPos)), (cell: CharCell, ci: number) => {
                          Span(cell.ch)
                            .fontSize(settings.scale(22))
                            .fontWeight(FontWeight.Medium)
                            .fontColor(lerpLyricColor(cell.amount, '#FFFFFF', '#99FFFFFF'))
                        }, (cell: CharCell, ci: number) => `ly_${index}_${ci}_${Math.round(cell.amount * 60)}`)
                      }
                      .textAlign(TextAlign.Center)
                      .width('100%')
                    } else {
                      Text(line.text)
                        .fontSize(settings.scale(22))
                        .fontWeight(FontWeight.Medium)
                        .fontColor('#FFFFFF')
                        .textAlign(TextAlign.Center)
                        .maxLines(3)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                    }

                    if (this.st.showTranslation && line.translation.length > 0) {
                      Text(line.translation)
                        .fontSize(settings.trans(11))
                        .fontColor('#E8DCD6')
                        .textAlign(TextAlign.Center)
                        .maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                    }
                  }
                  .width('100%')
                  .padding({ top: 12, bottom: 12 })
                  .scale({ x: this.lyricScale(index), y: this.lyricScale(index) })
                  .rotate({
                    x: 1,
                    y: 0,
                    z: 0,
                    angle: this.lyricTilt(index),
                    centerX: '50%',
                    centerY: '50%'
                  })
                  .opacity(this.lyricAlpha(index))
                  .animation({ duration: settings.motionMs(260), curve: Curve.FastOutSlowIn })
                  .onClick(() => {
                    audioPlayer.seek(line.timeMs);
                  })
                }
              }, (line: LyricLine) => `${line.timeMs}_${line.text}`)
            }
            .width('100%')
            .height('100%')
            .contentStartOffset(140)
            .contentEndOffset(140)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.None)

          }
          .width('100%')
          .layoutWeight(1)
          .margin({ top: 6, bottom: 4 })
        } else if (this.lyrics.plainText.length > 0) {
          Scroll() {
            Text(this.lyrics.plainText)
              .fontSize(settings.scale(17))
              .lineHeight(settings.scale(32))
              .fontColor('#E6DAD3')
              .textAlign(TextAlign.Center)
              .width('100%')
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .margin({ top: 10, bottom: 6 })
        } else {
          Column({ space: 10 }) {
            Text('暂无歌词')
              .fontSize(14)
              .fontColor('#D6C8C1')
            Text('把同名 .lrc / .yrc 放在歌曲旁边，或在设置里导入')
              .fontSize(10)
              .fontColor('#8E8079')
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        }

        Row() {
          Text('译')
            .fontSize(10)
            .fontColor(this.st.showTranslation ? '#1E1714' : '#E8DCD5')
            .width(27)
            .height(27)
            .textAlign(TextAlign.Center)
            .borderRadius(14)
            .backgroundColor(this.st.showTranslation ? '#EFE3DC' : '#33FFFFFF')
            .onClick(() => {
              settings.setShowTranslation(!this.st.showTranslation);
            })
          Blank()
        }
        .width('100%')
        .margin({ bottom: 8 })

        Row({ space: 10 }) {
          Text(formatTime(this.renderPos))
            .fontSize(9)
            .fontColor('#C9BBB4')
            .width(36)
          Slider({
            value: this.player.durationMs > 0 ? this.renderPos : 0,
            max: this.player.durationMs > 0 ? this.player.durationMs : 1,
            step: 1
          })
            .blockColor('#F5E9E2')
            .trackColor('#3DFFFFFF')
            .selectedColor('#F5E9E2')
            .trackThickness(2)
            .blockSize({ width: 9, height: 9 })
            .layoutWeight(1)
            .enabled(this.player.durationMs > 0)
            .onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                audioPlayer.seek(value);
              }
            })
          Text(formatTime(this.player.durationMs))
            .fontSize(9)
            .fontColor('#C9BBB4')
            .width(36)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: 34 }) {
          Stack() {
            this.glyph($r('app.media.ic_ctrl_prev'), '#F5EBE6', 26)
          }
          .width(44)
          .height(44)
          .onClick(() => {
            playback.previous();
          })

          Stack() {
            Circle()
              .width(52)
              .height(52)
              .fill('#F3E6DE')
            if (this.player.isPlaying) {
              Image($r('app.media.ic_pause'))
                .width(20)
                .height(20)
                .fillColor('#241C18')
                .draggable(false)
                .transition(TransitionEffect.scale({ x: 0.72, y: 0.72 })
                  .animation({ duration: settings.motionMs(300), curve: curves.springMotion(0.32, 0.72) })
                  .combine(TransitionEffect.OPACITY.animation({ duration: settings.motionMs(110) })))
            } else {
              Image($r('app.media.ic_play'))
                .width(20)
                .height(20)
                .fillColor('#241C18')
                .draggable(false)
                .transition(TransitionEffect.scale({ x: 0.72, y: 0.72 })
                  .animation({ duration: settings.motionMs(300), curve: curves.springMotion(0.32, 0.72) })
                  .combine(TransitionEffect.OPACITY.animation({ duration: settings.motionMs(110) })))
            }
          }
          .width(52)
          .height(52)
          .onClick(() => {
            audioPlayer.toggle();
          })

          Stack() {
            this.glyph($r('app.media.ic_ctrl_next'), '#F5EBE6', 26)
          }
          .width(44)
          .height(44)
          .onClick(() => {
            playback.next();
          })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .margin({ top: 6 })

        Column() {
          this.playerActionRow()
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('100%')
      .height('100%')
      .padding({
        left: 20,
        right: 20,
        top: this.topInset + 4,
        // 底部多留一点，别让控件压在手势条上
        bottom: this.bottomInset + 18
      })
    }
    .width('100%')
    .height('100%')
    .transition(this.sheetTransition(280, 220))
  }

  /**
   * 歌词行的变换参数，对齐安卓版 LyricVisualSpec：
   * activeScale 1.06、nearScale 0.95、farScale 0.88（每远一行再 -0.02，最低 0.8）；
   * 透明度 near 0.4 / far 0.35，更远每行 -0.08，最低 0.16；
   * 非当前行按上下位置做 ±9° 的翻转。
   */
  private lyricScale(index: number): number {
    const d = Math.abs(index - this.lyrics.currentIndex);
    if (d === 0) {
      return 1;
    }
    if (d === 1) {
      return 0.95;
    }
    const v = 0.88 - (d - 2) * 0.02;
    return v < 0.8 ? 0.8 : v;
  }

  private lyricAlpha(index: number): number {
    const d = Math.abs(index - this.lyrics.currentIndex);
    if (d === 0) {
      return 1;
    }
    if (d === 1) {
      return 0.40;
    }
    if (d === 2) {
      return 0.35;
    }
    const v = 0.35 - 0.08 * (d - 2);
    return v < 0.16 ? 0.16 : v;
  }

  private lyricTilt(index: number): number {
    if (index === this.lyrics.currentIndex) {
      return 0;
    }
    return index < this.lyrics.currentIndex ? 9 : -9;
  }

  @Builder
  queueOverlay() {
    Column() {
      Row({ space: 8 }) {
        Text('播放队列')
          .fontSize(16)
          .fontColor(TEXT_MAIN)
        Text(`${playback.queueLength()} 首`)
          .fontSize(10)
          .fontColor(TEXT_SUB)
        Blank()
        Text('清空')
          .fontSize(11)
          .fontColor('#FF6B6B')
          .height(40)
          .padding({ left: 10, right: 10 })
          .onClick(() => {
            this.clearQueue();
          })
        Text('✕')
          .fontSize(16)
          .fontColor(TEXT_SUB)
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.showQueue = false;
          })
      }
      .width('100%')
      .margin({ bottom: 10 })

      List({ space: 2 }) {
        ForEach(playback.getQueue(), (song: Song, index: number) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(`${index + 1}`)
                .fontSize(10)
                .fontColor(song.path === this.player.currentPath ? settings.accent() : '#5A4A42')
                .width(20)
                .textAlign(TextAlign.Center)

              Column({ space: 3 }) {
                Text(song.title)
                  .fontSize(13)
                  .fontColor(song.path === this.player.currentPath ? settings.accent() : TEXT_MAIN)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(song.artist.length > 0 ? song.artist : '未知艺术家')
                  .fontSize(10)
                  .fontColor(TEXT_SUB)
                  .maxLines(1)
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text(formatTime(song.durationMs))
                .fontSize(10)
                .fontColor(TEXT_SUB)
            }
            .width('100%')
            .padding({ top: 9, bottom: 9, left: 6, right: 6 })
            .borderRadius(12)
            .backgroundColor(song.path === this.player.currentPath ? settings.accentSoft(0.08) : '#00000000')
            .onClick(() => {
              playback.playIndex(index);
              this.showQueue = false;
            })
          }
        }, (song: Song) => song.path)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: this.topInset + 14, bottom: this.bottomInset + 12 })
    .linearGradient({
      angle: 170,
      colors: [[settings.tintBackdrop(0.16), 0.0], ['#2A211E', 0.45], ['#1A1817', 1.0]]
    })
    .transition(this.sheetTransition(260, 200))
  }

  // ─────────────────── 播放页 / 歌词页：沉浸式 ───────────────────

  /** 底部上滑的浮层（播放页 / 歌词页 / 队列 / 操作面板），对齐安卓 300ms 上滑 + 150ms 淡入 */
  private sheetTransition(enterMs: number, exitMs: number): TransitionEffect {
    const appear = TransitionEffect.OPACITY.animation({ duration: settings.motionMs(150), curve: Curve.FastOutSlowIn })
      .combine(TransitionEffect.translate({ y: '100%' })
        .animation({ duration: settings.motionMs(enterMs), curve: Curve.FastOutSlowIn }));
    const disappear = TransitionEffect.OPACITY.animation({ duration: settings.motionMs(120), curve: Curve.FastOutSlowIn })
      .combine(TransitionEffect.translate({ y: '100%' })
        .animation({ duration: settings.motionMs(exitMs), curve: Curve.FastOutSlowIn }));
    return TransitionEffect.asymmetric(appear, disappear);
  }

  /** 整页从右侧推入（艺人 / 评论 / MV），安卓导航的场景切换 */
  private routeTransition(enterMs: number, exitMs: number): TransitionEffect {
    const appear = TransitionEffect.OPACITY.animation({ duration: settings.motionMs(180), curve: Curve.FastOutSlowIn })
      .combine(TransitionEffect.translate({ x: '24%' })
        .animation({ duration: settings.motionMs(enterMs), curve: Curve.FastOutSlowIn }));
    const disappear = TransitionEffect.OPACITY.animation({ duration: settings.motionMs(140), curve: Curve.FastOutSlowIn })
      .combine(TransitionEffect.translate({ x: '24%' })
        .animation({ duration: settings.motionMs(exitMs), curve: Curve.FastOutSlowIn }));
    return TransitionEffect.asymmetric(appear, disappear);
  }

  /**
   * 对话框面板：只做缩放。
   * 遮罩层单独用 backdropTransition 淡入，不能把 scale 加在整层上——
   * 否则黑色遮罩会跟着一起缩小，四周露出页面。
   */
  private dialogTransition(): TransitionEffect {
    const appear = TransitionEffect.scale({ x: 0.92, y: 0.92 })
      .animation({ duration: settings.motionMs(220), curve: Curve.FastOutSlowIn });
    const disappear = TransitionEffect.scale({ x: 0.94, y: 0.94 })
      .animation({ duration: settings.motionMs(180), curve: Curve.FastOutSlowIn });
    return TransitionEffect.asymmetric(appear, disappear);
  }

  /** 遮罩层：只淡入淡出，始终铺满全屏 */
  private backdropTransition(): TransitionEffect {
    return TransitionEffect.OPACITY.animation({
      duration: settings.motionMs(160), curve: Curve.FastOutSlowIn
    });
  }

  /** 全屏背景：封面模糊 + 暗色渐层 */
  @Builder
  playerBackdropLayer() {
    Stack() {
      if (this.covers.cover !== null) {
        Image(this.covers.cover as image.PixelMap)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(48)
          .scale({ x: 1.3, y: 1.3 })
          .opacity(0.9)
          .draggable(false)
      } else if (this.remoteCoverUrl().length > 0) {
        Image(this.remoteCoverUrl())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(48)
          .scale({ x: 1.3, y: 1.3 })
          .opacity(0.9)
          .draggable(false)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 160,
            colors: [[this.playerBackdrop(), 0.0], ['#1A1512', 1.0]]
          })
      }

      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            ['#66000000', 0.0],
            ['#4D000000', 0.38],
            ['#E0120F0D', 0.80],
            ['#F7120F0D', 1.0]
          ]
        })
    }
    .width('100%')
    .height('100%')
  }

  /** 统一用自绘 SVG + fillColor 上色：Path 的坐标按 px 算，做不了自适应尺寸 */
  @Builder
  glyph(res: Resource, color: string, size: number = 24) {
    Image(res)
      .width(size)
      .height(size)
      .fillColor(color)
      .draggable(false)
  }

  /** 顶部的小图标按钮（44 点击区） */
  @Builder
  topIcon(res: Resource, color: string, onTap: () => void) {
    Stack() {
      this.glyph(res, color)
    }
    .width(44)
    .height(44)
    .onClick(onTap)
  }

  @Builder
  /**
   * 收藏按钮。注意这里不能带参数：
   * 带参 @Builder 会按参数缓存，内部读收藏状态不会跟着状态重绘，
   * 表现就是「已经收藏了但心还是空心」。
   */
  @Builder
  heartIcon() {
    if (this.isCurrentFavorite()) {
      Image($r('app.media.ic_nav_heart_on'))
        .width(23)
        .height(23)
        .fillColor('#FF6B6B')
        .draggable(false)
        .transition(TransitionEffect.scale({ x: 0.5, y: 0.5 })
          .animation({ duration: settings.motionMs(280), curve: curves.springMotion(0.34, 0.6) })
          .combine(TransitionEffect.OPACITY.animation({ duration: settings.motionMs(120) })))
    } else {
      Image($r('app.media.ic_nav_heart'))
        .width(23)
        .height(23)
        .fillColor('#F2E8E3')
        .draggable(false)
        .transition(TransitionEffect.scale({ x: 0.8, y: 0.8 })
          .animation({ duration: settings.motionMs(200), curve: Curve.FastOutSlowIn })
          .combine(TransitionEffect.OPACITY.animation({ duration: settings.motionMs(120) })))
    }
  }

  @Builder
  moreButton(color: string, onTap: () => void) {
    Stack() {
      this.glyph($r('app.media.ic_nav_more'), color, 22)
    }
    .width(44)
    .height(44)
    .onClick(onTap)
  }

  /** 固定文案的按钮：队列 / 下载 / 歌单。参数不会变，用带参 Builder 没问题 */
  @Builder
  actionButton(icon: Resource, label: string, onTap: () => void) {
    Column({ space: 4 }) {
      this.glyph(icon, '#EADDD6', 22)
      Text(label)
        .fontSize(9)
        .fontColor('#A5978F')
        .maxLines(1)
    }
    .width(58)
    .height(46)
    .justifyContent(FlexAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .onClick(onTap)
  }

  /**
   * 定时按钮。文字和颜色必须在这里直接读状态，不能当参数传：
   * 带参 @Builder 的参数只在首次构建时求值，父级重绘也不会更新。
   */
  @Builder
  timerActionButton() {
    Column({ space: 4 }) {
      this.glyph($r('app.media.ic_act_timer'),
        this.sleepMinutes > 0 ? settings.accent() : '#EADDD6', 22)
      Text(this.timerLabel())
        .fontSize(9)
        .fontColor(this.sleepMinutes > 0 ? settings.accent() : '#A5978F')
        .maxLines(1)
    }
    .width(58)
    .height(46)
    .justifyContent(FlexAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .onClick(() => {
      this.cycleSleepTimer();
    })
  }

  /** 歌词按钮，active 状态同样直接读 showLyrics */
  @Builder
  lyricActionButton() {
    Column({ space: 4 }) {
      Text('词')
        .fontSize(18)
        .fontWeight(this.showLyrics ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.showLyrics ? settings.accent() : '#EADDD6')
        .height(24)
      Text('歌词')
        .fontSize(9)
        .fontColor(this.showLyrics ? settings.accent() : '#A5978F')
        .maxLines(1)
    }
    .width(58)
    .height(46)
    .justifyContent(FlexAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .onClick(() => {
      this.toggleLyrics();
    })
  }

  /** 底部一排：队列 / 定时 / 下载 / 歌词 / 加入歌单 */
  @Builder
  playerActionRow() {
    Row() {
      this.actionButton($r('app.media.ic_act_queue'), '队列', () => {
        this.showQueue = true;
      })

      this.timerActionButton()

      this.actionButton($r('app.media.ic_act_download'), '下载', () => {
        this.downloadCurrent();
      })

      // 宽屏歌词常驻右屏，不再需要单独的全屏歌词入口
      if (!this.isWide) {
        this.lyricActionButton()
      }

      this.actionButton($r('app.media.ic_act_listadd'), '加歌单', () => {
        this.openPlaylistPicker();
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
  }

  /** 随机：三种模式用两个分支区分，切模式时节点重建，颜色才会跟着变 */
  @Builder
  shuffleButton() {
    Stack() {
      if (this.playMode === PlayMode.SHUFFLE) {
        this.glyph($r('app.media.ic_ctrl_shuffle'), settings.accent())
      } else {
        this.glyph($r('app.media.ic_ctrl_shuffle'), '#EADDD6')
      }
    }
    .width(44)
    .height(44)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
    .onClick(() => {
      this.toggleShuffle();
    })
  }

  /** 循环：顺序与单曲用不同图标，单曲那个中间带「1」 */
  @Builder
  repeatButton() {
    Stack() {
      if (this.playMode === PlayMode.SINGLE) {
        this.glyph($r('app.media.ic_ctrl_repeat_one'), settings.accent())
      } else if (this.playMode === PlayMode.SEQUENCE) {
        this.glyph($r('app.media.ic_ctrl_repeat'), settings.accent())
      } else if (this.lastLoopMode === PlayMode.SINGLE) {
        // 随机态：灰色显示上次选的循环方式，点一下就切回去
        this.glyph($r('app.media.ic_ctrl_repeat_one'), '#EADDD6')
      } else {
        this.glyph($r('app.media.ic_ctrl_repeat'), '#EADDD6')
      }
    }
    .width(44)
    .height(44)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
    .onClick(() => {
      this.switchLoopMode();
    })
  }

  /** 播放页：大封面 + 标题 + 进度 + 五个控制键 */
  /**
   * 宽屏播放页：左列封面与控制，右列歌词常驻。
   * 折叠屏展开、平板横屏时替代竖排布局，省掉「播放页 / 歌词页」来回切。
   */
  @Builder
  widePlayer() {
    Row() {
      // ── 左屏：除歌词外的所有控件，整块水平居中 ──
      Column() {
        Column() {
          Row() {
            this.topIcon($r('app.media.ic_nav_back'), '#F2E8E3', () => {
              this.closePlayer();
            })
            Blank()
            Stack() {
              this.heartIcon()
            }
            .width(40)
            .height(40)
            .onClick(() => {
              const song = playback.currentSong();
              if (song !== null) {
                this.toggleFavorite(song);
              }
            })
            if (this.currentIsRemote()) {
              this.topIcon($r('app.media.ic_nav_comment'), '#F2E8E3', () => {
                const song = playback.currentSong();
                if (song !== null) {
                  neteaseComment.open(song);
                }
              })
            }
            this.moreButton('#F2E8E3', () => {
              const song = playback.currentSong();
              if (song !== null) {
                this.showSongMenu(song);
              }
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 顶部留白少于中缝，整块内容略微上偏
          Column()
            .width('100%')
            .layoutWeight(2)

          // 封面与歌曲信息同宽，左边缘才对得齐
          Column() {
            Stack() {
              if (this.covers.cover !== null) {
                Image(this.covers.cover as image.PixelMap)
                  .width('100%')
                  .height('100%')
                  .objectFit(ImageFit.Cover)
                  .draggable(false)
              } else if (this.remoteCoverUrl().length > 0) {
                Image(this.remoteCoverUrl())
                  .width('100%')
                  .height('100%')
                  .objectFit(ImageFit.Cover)
                  .draggable(false)
              } else {
                Column() {
                  Image($r('app.media.ic_note'))
                    .width(48)
                    .height(48)
                    .fillColor('#8C7C74')
                    .draggable(false)
                }
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Center)
              }
            }
            .width('100%')
            .aspectRatio(1)
            .borderRadius(16)
            .clip(true)
            .backgroundColor('#1FFFFFFF')
            .shadow({ radius: 30, color: '#73000000', offsetX: 0, offsetY: 14 })

            Column({ space: 4 }) {
              Text(this.player.title.length > 0 ? this.player.title : '未在播放')
                .fontSize(21)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(this.currentArtist())
                .fontSize(12)
                .fontColor('#D8CAC3')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .onClick(() => {
                  const song = playback.currentSong();
                  if (song !== null && song.artistId > 0) {
                    this.openArtist(song.artistId, song.artist);
                  }
                })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .margin({ top: 12 })
          }
          .width(this.wideCover)

          Column()
            .width('100%')
            .layoutWeight(3)

          Row({ space: 8 }) {
            Text(formatTime(this.renderPos))
              .fontSize(9)
              .fontColor('#C9BBB4')
              .width(34)
            Slider({
              value: this.player.durationMs > 0 ? this.renderPos : 0,
              max: this.player.durationMs > 0 ? this.player.durationMs : 1,
              step: 1
            })
              .blockColor('#F5E9E2')
              .trackColor('#3DFFFFFF')
              .selectedColor('#F5E9E2')
              .trackThickness(2)
              .blockSize({ width: 9, height: 9 })
              .layoutWeight(1)
              .enabled(this.player.durationMs > 0)
              .onChange((value: number, mode: SliderChangeMode) => {
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  audioPlayer.seek(value);
                }
              })
            Text(formatTime(this.player.durationMs))
              .fontSize(9)
              .fontColor('#C9BBB4')
              .width(34)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(this.qualityText())
            .fontSize(9)
            .fontColor('#A5978F')
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 12 })

          Row() {
            this.shuffleButton()

            Stack() {
              this.glyph($r('app.media.ic_ctrl_prev'), '#F5EBE6', 24)
            }
            .width(40)
            .height(40)
            .onClick(() => {
              playback.previous();
            })

            Stack() {
              Circle()
                .width(54)
                .height(54)
                .fill('#F3E6DE')
              if (this.player.isPlaying) {
                Image($r('app.media.ic_pause'))
                  .width(20)
                  .height(20)
                  .fillColor('#241C18')
                  .draggable(false)
              } else {
                Image($r('app.media.ic_play'))
                  .width(20)
                  .height(20)
                  .fillColor('#241C18')
                  .draggable(false)
              }
            }
            .width(54)
            .height(54)
            .opacity(this.player.isLoading ? 0.6 : 1)
            .onClick(() => {
              audioPlayer.toggle();
            })

            Stack() {
              this.glyph($r('app.media.ic_ctrl_next'), '#F5EBE6', 24)
            }
            .width(40)
            .height(40)
            .onClick(() => {
              playback.next();
            })

            this.repeatButton()
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)
          .alignItems(VerticalAlign.Center)
          .margin({ top: 20 })

          Column() {
            this.playerActionRow()
          }
          .width('100%')
          .margin({ top: 22 })
        }
        .width(this.wideColW)
        .layoutWeight(1)
      }
      .layoutWeight(11)
      .height('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 14 })

      // ── 右屏：只有歌词，水平垂直都居中 ──
      Column() {
        this.wideLyricPanel()
      }
      .layoutWeight(9)
      .height('100%')
      // 上下各留一点，歌词边界才和左屏顶栏、功能行对齐
      .padding({ top: 10, bottom: 10 })
      .clip(true)
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 24,
      right: 24,
      top: this.topInset + 4,
      // 底部多留一点，别让功能行压在手势条上
      bottom: this.bottomInset + 18
    })
  }
  /** 宽屏播放浮层：背景 + 左右分栏，与竖排版本共存 */
  @Builder
  widePlayerOverlay() {
    Stack() {
      this.playerBackdropLayer()
      this.widePlayer()
    }
    .width('100%')
    .height('100%')
    .transition(this.sheetTransition(300, 250))
  }

  /** 宽屏播放页右栏歌词：当前行高亮，点击跳转；独立滚动控制器 */
  @Builder
  wideLyricPanel() {
    Column() {
      if (this.lyrics.hasLyric) {
        List({ scroller: this.wideScroller }) {
          ForEach(this.lyrics.lines, (line: LyricLine, index: number) => {
            ListItem() {
              Column({ space: 3 }) {
                Text(line.text)
                  .fontSize(settings.scale(18))
                  .fontWeight(index === this.lyrics.currentIndex ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(index === this.lyrics.currentIndex ? '#FFFFFF' : '#8E8079')
                  .textAlign(TextAlign.Center)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                if (this.st.showTranslation && line.translation.length > 0) {
                  Text(line.translation)
                    .fontSize(settings.trans(11))
                    .fontColor('#B3A49C')
                    .textAlign(TextAlign.Center)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
              .padding({ top: 7, bottom: 7 })
              .onClick(() => {
                audioPlayer.seek(line.timeMs);
              })
            }
          }, (line: LyricLine) => `wl_${line.timeMs}_${line.text}`)
        }
        .width('100%')
        .layoutWeight(1)
        .contentStartOffset(240)
        .contentEndOffset(240)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)
      } else if (this.lyrics.plainText.length > 0) {
        Scroll() {
          Text(this.lyrics.plainText)
            .fontSize(settings.scale(15))
            .lineHeight(settings.scale(26))
            .fontColor('#C9BBB4')
            .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      } else {
        Column() {
          Text('暂无歌词')
            .fontSize(13)
            .fontColor('#8E8079')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  playerOverlay() {
    Stack() {
      this.playerBackdropLayer()

      Column() {
        Row() {
          this.topIcon($r('app.media.ic_nav_back'), '#F2E8E3', () => {
            this.closePlayer();
          })
          Blank()
          Stack() {
            this.heartIcon()
          }
          .width(44)
          .height(44)
          .onClick(() => {
            const song = playback.currentSong();
            if (song !== null) {
              this.toggleFavorite(song);
            }
          })
          if (this.currentIsRemote()) {
            this.topIcon($r('app.media.ic_nav_comment'), '#F2E8E3', () => {
              const song = playback.currentSong();
              if (song !== null) {
                neteaseComment.open(song);
              }
            })
          }
          this.moreButton('#F2E8E3', () => {
            const song = playback.currentSong();
            if (song !== null) {
              this.showSongMenu(song);
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 上方弹性留白：封面与歌名整体往下走一点
        Column()
          .width('100%')
          .layoutWeight(3)

        Stack() {
          if (this.covers.cover !== null) {
            Image(this.covers.cover as image.PixelMap)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .draggable(false)
          } else if (this.remoteCoverUrl().length > 0) {
            Image(this.remoteCoverUrl())
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .draggable(false)
          } else {
            Column() {
              Image($r('app.media.ic_note'))
                .width(56)
                .height(56)
                .fillColor('#8C7C74')
                .draggable(false)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
          }
        }
        .width('100%')
        .aspectRatio(1)
        // 矮宽窗口下按可用高度收窄，避免把下方控件顶出去
        .constraintSize({ maxWidth: this.narrowCover })
        .borderRadius(14)
        .clip(true)
        .backgroundColor('#1FFFFFFF')
        .shadow({ radius: 30, color: '#73000000', offsetX: 0, offsetY: 14 })
        .margin({ top: 10 })

        Column({ space: 6 }) {
          Text(this.player.title.length > 0 ? this.player.title : '未在播放')
            .fontSize(26)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.currentArtist())
            .fontSize(13)
            .fontColor('#D8CAC3')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .onClick(() => {
              const song = playback.currentSong();
              if (song !== null && song.artistId > 0) {
                this.openArtist(song.artistId, song.artist);
              }
            })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .margin({ top: 22 })

        // 中间留白比上下都大，但不再吃掉整块屏幕
        Column()
          .width('100%')
          .layoutWeight(3)

        Row({ space: 10 }) {
          Text(formatTime(this.renderPos))
            .fontSize(9)
            .fontColor('#C9BBB4')
            .width(36)
          Slider({
            value: this.player.durationMs > 0 ? this.renderPos : 0,
            max: this.player.durationMs > 0 ? this.player.durationMs : 1,
            step: 1
          })
            .blockColor('#F5E9E2')
            .trackColor('#3DFFFFFF')
            .selectedColor('#F5E9E2')
            .trackThickness(2)
            .blockSize({ width: 9, height: 9 })
            .layoutWeight(1)
            .enabled(this.player.durationMs > 0)
            .onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                audioPlayer.seek(value);
              }
            })
          Text(formatTime(this.player.durationMs))
            .fontSize(9)
            .fontColor('#C9BBB4')
            .width(36)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.qualityText())
          .fontSize(9)
          .fontColor('#A5978F')
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 5 })

        Row() {
          this.shuffleButton()

          Stack() {
            this.glyph($r('app.media.ic_ctrl_prev'), '#F5EBE6', 26)
          }
          .width(44)
          .height(44)
          .onClick(() => {
            playback.previous();
          })

          Stack() {
            Circle()
              .width(64)
              .height(64)
              .fill('#F3E6DE')
            if (this.player.isPlaying) {
              Image($r('app.media.ic_pause'))
                .width(24)
                .height(24)
                .fillColor('#241C18')
                .draggable(false)
                .transition(TransitionEffect.scale({ x: 0.72, y: 0.72 })
                  .animation({ duration: settings.motionMs(300), curve: curves.springMotion(0.32, 0.72) })
                  .combine(TransitionEffect.OPACITY.animation({ duration: settings.motionMs(110) })))
            } else {
              Image($r('app.media.ic_play'))
                .width(24)
                .height(24)
                .fillColor('#241C18')
                .draggable(false)
                .transition(TransitionEffect.scale({ x: 0.72, y: 0.72 })
                  .animation({ duration: settings.motionMs(300), curve: curves.springMotion(0.32, 0.72) })
                  .combine(TransitionEffect.OPACITY.animation({ duration: settings.motionMs(110) })))
            }
          }
          .width(64)
          .height(64)
          .opacity(this.player.isLoading ? 0.6 : 1)
          .onClick(() => {
            audioPlayer.toggle();
          })

          Stack() {
            this.glyph($r('app.media.ic_ctrl_next'), '#F5EBE6', 26)
          }
          .width(44)
          .height(44)
          .onClick(() => {
            playback.next();
          })

          this.repeatButton()
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .margin({ top: 12 })

        // 留白放在按钮行之前：进度条与控制键位置不动，五个功能按钮整体往下靠
        Column()
          .width('100%')
          .layoutWeight(1)

        Column() {
          this.playerActionRow()
        }
        .width('100%')
        .margin({ top: 14 })
      }
      .width('100%')
      .height('100%')
      // 宽屏下整列限宽居中：封面、歌名、进度条左边缘才会对齐，
      // 否则封面被单独限宽、文字仍铺满，会错位成两套网格
      .constraintSize({ maxWidth: 440 })
      .padding({
        left: 20,
        right: 20,
        top: this.topInset + 4,
        // 底部多留一点，别让控件压在手势条上
        bottom: this.bottomInset + 18
      })
    }
    .width('100%')
    .height('100%')
    .transition(this.sheetTransition(300, 250))
  }

  private currentLyricLine(): LyricLine | null {
    const idx = this.lyrics.currentIndex;
    if (idx < 0 || idx >= this.lyrics.lines.length) {
      return null;
    }
    return this.lyrics.lines[idx];
  }

  private currentLyricCells(): CharCell[] {
    const line = this.currentLyricLine();
    if (line === null) {
      return [];
    }
    return cellsForLine(line, lyric.adjust(this.renderPos));
  }

  private currentTranslation(): string {
    const line = this.currentLyricLine();
    return line === null ? '' : line.translation;
  }

  private neighborText(offset: number): string {
    const idx = this.lyrics.currentIndex + offset;
    if (idx < 0 || idx >= this.lyrics.lines.length) {
      return '';
    }
    return this.lyrics.lines[idx].text;
  }

  private offsetLabel(): string {
    const v = this.lyrics.offsetMs / 1000;
    if (v === 0) {
      return '同步';
    }
    return `${v > 0 ? '+' : ''}${v.toFixed(1)}s`;
  }

  /** 轻提示：点完按钮给一句人话反馈，避免「按了不知道发生了什么」 */
  private toast(message: string): void {
    if (message.length === 0) {
      return;
    }
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1600 });
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`toast 失败 ${err.code}: ${err.message}`);
    }
  }

  /** 定时按钮上的文字：没开就是「定时」，开了显示分钟数 */
  private timerLabel(): string {
    const minutes = this.sleepMinutes;
    return minutes > 0 ? `${minutes} 分` : '定时';
  }

  /** 关闭 → 15 → 30 → 60 → 关闭，每次都提示当前设定 */
  private cycleSleepTimer(): void {
    const next = sleepTimer.cycle();
    this.sleepMinutes = next;
    this.toast(next <= 0 ? '睡眠定时已关闭' : `将在 ${next} 分钟后暂停播放`);
  }

  /** 下载当前曲目：已有的、本地的一律给出明确说法 */
  private async downloadCurrent(): Promise<void> {
    const song = playback.currentSong();
    if (song === null) {
      this.toast('还没有在播放的歌曲');
      return;
    }
    if (!song.isRemote()) {
      this.toast('本地歌曲，不需要下载');
      return;
    }
    const exist = downloader.find(song.path);
    if (exist !== null) {
      this.toast(exist.status === DownloadStatus.DONE ? '这首歌已经下载过了' : '已经在下载列表里');
      return;
    }
    this.toast('正在解析下载地址…');
    await downloader.enqueue(song);
    this.toast(downloader.state.message);
  }

  /** 随机键：只开关随机。关掉时回到关之前那种循环方式 */
  private toggleShuffle(): void {
    if (this.playMode === PlayMode.SHUFFLE) {
      const back = this.lastLoopMode === PlayMode.SINGLE ? PlayMode.SINGLE : PlayMode.SEQUENCE;
      playback.setMode(back);
      this.playMode = back;
      this.toast('随机播放已关闭');
      return;
    }
    this.lastLoopMode = this.playMode;
    playback.setMode(PlayMode.SHUFFLE);
    this.playMode = PlayMode.SHUFFLE;
    this.toast('随机播放');
  }

  /** 循环键：只在列表循环与单曲循环之间切；随机开着时先退出随机 */
  private switchLoopMode(): void {
    const base = this.playMode === PlayMode.SHUFFLE ? this.lastLoopMode : this.playMode;
    const next = base === PlayMode.SINGLE ? PlayMode.SEQUENCE : PlayMode.SINGLE;
    this.lastLoopMode = next;
    playback.setMode(next);
    this.playMode = next;
    this.toast(next === PlayMode.SINGLE ? '单曲循环' : '列表循环');
  }

  /** 歌词页里再点一次就回播放页，两个方向都有反应 */
  private toggleLyrics(): void {
    if (this.showLyrics) {
      this.showLyrics = false;
      return;
    }
    this.scrolledIndex = -1;
    this.showLyrics = true;
  }

  private openPlaylistPicker(): void {
    const song = playback.currentSong();
    if (song === null) {
      this.toast('还没有在播放的歌曲');
      return;
    }
    this.pickerPath = song.path;
  }

  /** 当前曲目是否已收藏 */
  private isCurrentFavorite(): boolean {
    return this.favPaths.indexOf(this.player.currentPath) >= 0;
  }

  /** 播放页音质行：档位 · 格式 · 码率；本地文件只报来源 */
  private qualityText(): string {
    if (!this.player.currentPath.startsWith('netease://')) {
      const song = playback.currentSong();
      if (song === null) {
        return '本地文件';
      }
      const parts: string[] = [];
      const dot = song.fileName.lastIndexOf('.');
      if (dot >= 0) {
        parts.push(song.fileName.substring(dot + 1).toUpperCase());
      }
      if (song.durationMs > 0 && song.sizeBytes > 0) {
        parts.push(`${Math.round(song.sizeBytes * 8 / song.durationMs)} kbps`);
      }
      return parts.length > 0 ? parts.join(' · ') : '本地文件';
    }
    const info = netease.state.lastUrlInfo;
    if (info.url.length === 0) {
      return '在线音源';
    }
    const parts: string[] = [];
    const level = this.qualityLevelText(info.level);
    if (level.length > 0) {
      parts.push(level);
    }
    if (info.type.length > 0) {
      parts.push(info.type.toUpperCase());
    }
    if (info.br > 0) {
      parts.push(`${Math.round(info.br / 1000)} kbps`);
    }
    return parts.join(' · ');
  }

  private qualityLevelText(level: string): string {
    if (level === 'jymaster') {
      return '超清母带';
    }
    if (level === 'hires') {
      return 'Hi-Res';
    }
    if (level === 'lossless') {
      return '无损';
    }
    if (level === 'exhigh') {
      return '极高';
    }
    if (level === 'higher') {
      return '较高';
    }
    if (level === 'sky') {
      return '沉浸环绕';
    }
    if (level === 'jyeffect') {
      return '高清环绕';
    }
    if (level === 'standard') {
      return '标准';
    }
    return '';
  }

  /** 播放页底色：有封面主色就用它，否则退回主题色混色 */
  private playerBackdrop(): string {
    return this.covers.backdrop.length > 0 ? this.covers.backdrop : settings.tintBackdrop(0.16);
  }

  /** 圆盘染色：优先封面主色，没有就用主题色 */
  private discTint(alpha: number): string {
    const base = this.covers.dominant.length > 0 ? this.covers.dominant : settings.accent();
    return settings.withAlpha(base, alpha);
  }

  private currentIsRemote(): boolean {
    const song = playback.currentSong();
    return song !== null && song.isRemote();
  }

  private currentArtist(): string {
    // 必须读 @Trace 的 player.artist：currentSong() 不在状态系统里，切歌不会重绘
    if (this.player.artist.length > 0) {
      return this.player.artist;
    }
    return '未知艺术家';
  }

  private openPlayer(): void {
    this.showPlayer = true;
    cover.load(this.player.currentPath);
    this.startLyricTicker();
  }

  private closePlayer(): void {
    this.showPlayer = false;
    this.stopLyricTicker();
  }

  private startLyricTicker(): void {
    if (this.lyricTimer >= 0) {
      return;
    }
    // 30fps：位置本身是插值出来的，逐字颜色才不会一格一格跳
    this.lyricTimer = setInterval(() => {
      this.tickLyric();
    }, 33);
    this.tickLyric();
  }

  private stopLyricTicker(): void {
    if (this.lyricTimer >= 0) {
      clearInterval(this.lyricTimer);
      this.lyricTimer = -1;
    }
  }

  /**
   * 音频进度回调之间的插值，逻辑对齐 Android 版 InterpolatedPlaybackPosition：
   * - 暂停、或与真实进度差 ≥220ms（seek/切歌）→ 直接对齐；
   * - 否则以真实进度为锚点，锚点之后按流逝时间和倍速往前推；
   * - 真实进度比渲染值小的时候不往回跳（220ms 以内），避免抖动。
   */
  private updateRenderPos(): void {
    const raw = this.player.positionMs;
    const now = Date.now();
    const speed = this.player.speed > 0 ? this.player.speed : 1;
    const changed = this.lastRawPos < 0 || Math.abs(raw - this.lastRawPos) > 20;

    if (!this.player.isPlaying || Math.abs(raw - this.renderPos) >= 220) {
      this.lastRawPos = raw;
      this.posAnchorMs = raw;
      this.posAnchorAt = now;
      this.renderPos = raw;
      return;
    }
    if (changed) {
      const target = raw > this.renderPos ? raw : this.renderPos;
      this.lastRawPos = raw;
      this.posAnchorMs = target;
      this.posAnchorAt = now;
      this.renderPos = target;
      return;
    }
    const predicted = this.posAnchorMs + (now - this.posAnchorAt) * speed;
    if (this.player.durationMs > 0 && predicted > this.player.durationMs) {
      this.renderPos = this.player.durationMs;
      return;
    }
    this.renderPos = predicted;
  }

  private tickCount: number = 0;

  private tickLyric(): void {
    this.tickCount++;
    // 定时到点会自己把 minutes 归零，这里跟着同步，按钮文字才不会停在「15 分」
    if (this.sleepMinutes !== sleepTimer.state.minutes) {
      this.sleepMinutes = sleepTimer.state.minutes;
    }
    // 迷你播放器等其它入口也能切模式，这里跟着同步
    if (this.playMode !== playback.modeState.mode) {
      this.playMode = playback.modeState.mode;
    }
    // 只有歌词页需要 30fps；单纯播放页 8fps 就够，别让整页跟着重绘
    if (!this.showLyrics && this.tickCount % 4 !== 0) {
      return;
    }
    this.updateRenderPos();
    const path = this.player.currentPath;
    if (path !== this.lyricPath) {
      this.lyricPath = path;
      this.scrolledIndex = -1;
    }
    cover.load(path);
    // 唱片转动：和歌词同一个 ticker（120ms），每拍走 2°≈16.7°/s
    if (this.player.isPlaying && this.showPlayer) {
      this.discAngle += 2;
    }
    // 歌词加载与行推进统一交给服务层：后台播控中心靠它拿歌词
    lyric.syncTo(playback.currentSong(), this.renderPos);
    const idx = this.lyrics.currentIndex;
    if (idx >= 0 && idx !== this.scrolledIndex) {
      this.scrolledIndex = idx;
      if (this.showLyrics) {
        this.scroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
      }
      // 宽屏播放页右栏歌词同步跟随；首帧布局未完成时忽略
      if (this.showPlayer && this.isWide) {
        try {
          this.wideScroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
        } catch (e) {
          Logger.w('宽屏歌词滚动尚未就绪');
        }
      }
    }
  }

  /** 在线曲目的封面地址，本地曲目返回空串 */
  private remoteCoverUrl(): string {
    const song = playback.currentSong();
    // 下载后的曲目是本地文件，但 coverUrl 还留着，同样走网络图
    if (song !== null && song.coverUrl.length > 0 && song.path === this.player.currentPath) {
      return song.coverUrl;
    }
    return '';
  }

  private modeLabel(): string {
    const m = this.playMode;
    if (m === PlayMode.SHUFFLE) {
      return '随机';
    }
    if (m === PlayMode.SINGLE) {
      return '单曲';
    }
    return '顺序';
  }

  private isCurrent(song: Song): boolean {
    return this.player.currentPath === song.path;
  }

  private subtitle(song: Song): string {
    const artist = song.artist.length > 0 ? song.artist : '未知艺术家';
    if (song.album.length > 0) {
      return `${artist} · ${song.album}`;
    }
    return artist;
  }

  /** 后台逐张解缩略图，一次一张，曲库变了就放弃这一轮 */
  private async startThumbQueue(): Promise<void> {
    this.thumbToken++;
    const token = this.thumbToken;
    const songs = this.lib.songs;
    const limit = songs.length < 300 ? songs.length : 300;
    for (let i = 0; i < limit; i++) {
      if (token !== this.thumbToken) {
        return;
      }
      await cover.loadThumb(songs[i].path);
    }
  }

  /** 长按歌曲行：加入歌单 / 从曲库移除 */
  private showSongMenu(song: Song): void {
    const fav = this.favPaths.indexOf(song.path) >= 0;
    const buttons: AlertDialogButtonOptions[] = [
      {
        value: fav ? '取消收藏' : '收藏',
        action: () => {
          this.toggleFavorite(song);
        }
      },
      {
        value: '加入歌单',
        action: () => {
          this.pickerPath = song.path;
        }
      },
      {
        value: '从曲库移除',
        fontColor: '#FF6B6B',
        action: () => {
          this.doRemove(song);
        }
      },
      {
        value: '取消',
        action: () => {
        }
      }
    ];
    const options: AlertDialogParamWithOptions = {
      title: song.title,
      message: song.artist.length > 0 ? song.artist : '未知艺术家',
      buttons: buttons
    };
    this.getUIContext().showAlertDialog(options);
  }

  private showFavoriteMenu(song: Song): void {
    const buttons: AlertDialogButtonOptions[] = [
      {
        value: '取消收藏',
        fontColor: '#FF6B6B',
        action: () => {
          this.toggleFavorite(song);
        }
      },
      {
        value: '加入歌单',
        action: () => {
          this.pickerPath = song.path;
        }
      },
      {
        value: '取消',
        action: () => {
        }
      }
    ];
    const options: AlertDialogParamWithOptions = {
      title: song.title,
      message: '在收藏里',
      buttons: buttons
    };
    this.getUIContext().showAlertDialog(options);
  }

  private confirmRemoveFromPlaylist(song: Song): void {
    this.getUIContext().showAlertDialog({
      title: '从歌单移除',
      message: `「${song.title}」只会从歌单移除，不影响曲库。`,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '移除',
        fontColor: '#FF6B6B',
        action: () => {
          playlists.removeSong(this.playlistId, song.path);
        }
      }
    });
  }

  private confirmDeletePlaylist(list: Playlist): void {
    this.getUIContext().showAlertDialog({
      title: '删除歌单',
      message: `「${list.name}」会被删除，歌曲本身不受影响。`,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#FF6B6B',
        action: () => {
          playlists.removeList(list.id);
          if (this.playlistId === list.id) {
            this.playlistId = '';
          }
        }
      }
    });
  }

  private groupSamplePath(): string {
    const songs = library.songsOfGroup(this.viewMode === 1, this.groupKey);
    return songs.length > 0 ? songs[0].path : '';
  }

  private groupInitial(): string {
    return this.groupKey.length > 0 ? this.groupKey.charAt(0) : '?';
  }

  private groupStats(): string {
    const songs = library.songsOfGroup(this.viewMode === 1, this.groupKey);
    if (this.viewMode === 1) {
      const artist = songs.length > 0 && songs[0].artist.length > 0 ? songs[0].artist : '未知艺术家';
      return `${artist} · ${songs.length} 首`;
    }
    const albums: string[] = [];
    for (let i = 0; i < songs.length; i++) {
      const album = songs[i].album.length > 0 ? songs[i].album : '未知专辑';
      if (albums.indexOf(album) < 0) {
        albums.push(album);
      }
    }
    return `${songs.length} 首 · ${albums.length} 张专辑`;
  }

  private playGroup(): void {
    const songs = library.songsOfGroup(this.viewMode === 1, this.groupKey);
    if (songs.length === 0) {
      return;
    }
    playback.setQueue(songs);
    playback.playIndex(0);
  }

  private barHeight(count: number): number {
    const max = stats.maxDayCount();
    if (count <= 0) {
      return 4;
    }
    return Math.round(8 + 78 * (count / max));
  }

  private listenTimeText(): string {
    const minutes = Math.round(this.statsState.totalMs / 60000);
    if (minutes < 60) {
      return `${minutes} 分`;
    }
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    return `${h}h ${m}m`;
  }

  private companionDays(): number {
    const first = this.statsState.firstPlayAt;
    if (first === 0) {
      return 0;
    }
    const days = Math.ceil((Date.now() - first) / 86400000);
    return days < 1 ? 1 : days;
  }

  private playStatsSong(item: StatsTopItem): void {
    for (let i = 0; i < this.lib.songs.length; i++) {
      if (this.lib.songs[i].path === item.path) {
        playback.playSong(this.lib.songs[i], this.lib.songs);
        return;
      }
    }
    this.lib.message = '这首歌已不在曲库中';
  }

  private confirmClearHistory(): void {
    this.getUIContext().showAlertDialog({
      title: '清空播放历史',
      message: '统计和「最近播放」都会清空，不影响曲库、歌单和收藏。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: '#FF6B6B',
        action: () => {
          stats.clear().then(() => {
            this.refreshRecent();
            this.lib.message = '播放历史已清空';
          });
        }
      }
    });
  }

  private async onModeChanged(mode: number): Promise<void> {
    if (mode === 4) {
      this.refreshRecent();
    } else if (mode === 5) {
      this.refreshFavorites();
    } else if (mode === 6) {
      // 统计页先等数据就绪再显示，否则 ForEach 首次渲染时 top 还是空
      await stats.refresh();
    } else if (mode === 7) {
      // 在线页首次进入时拉推荐，失败就留在页面上让用户重试
      await netease.loadHome();
    } else if (mode === 8) {
      // 下载页有自己的提示，曲库的「已恢复 N 首」在这儿只会让人误解
      this.lib.message = '';
      // 老下载没有歌词，进页面时补一次；补完如果正在放这首，让歌词重新读
      downloader.ensureLyrics().then(() => {
        const song = playback.currentSong();
        if (song !== null && !song.isRemote()) {
          lyric.reloadForAudio(song.path);
        }
      });
    }
  }

  private async refreshRecent(): Promise<void> {
    const paths = await db.recentPaths(60);
    const out: Song[] = [];
    for (let i = 0; i < paths.length; i++) {
      for (let j = 0; j < this.lib.songs.length; j++) {
        if (this.lib.songs[j].path === paths[i]) {
          out.push(this.lib.songs[j]);
          break;
        }
      }
    }
    this.recentSongs = out;
  }

  private async refreshFavorites(): Promise<void> {
    const paths = await db.favoritePaths();
    this.favPaths = paths;
    this.favoriteSongs = library.resolvePaths(paths);
  }

  private async toggleFavorite(song: Song): Promise<void> {
    if (this.favPaths.indexOf(song.path) >= 0) {
      await db.removeFavorite(song.path);
      this.lib.message = `已取消收藏「${song.title}」`;
    } else {
      await db.addFavorite(song.path);
      // 在线曲目要把元数据留一份，否则收藏页找不到它
      if (song.isRemote()) {
        library.rememberRemote(song);
        await db.saveRemoteSong(song);
      }
      this.lib.message = `已收藏「${song.title}」`;
    }
    await this.refreshFavorites();
  }

  private currentPlaylistName(): string {
    const list = playlists.find(this.playlistId);
    return list === null ? '' : list.name;
  }

  private playPlaylist(): void {
    const songs = playlists.songsOf(this.playlistId);
    if (songs.length === 0) {
      this.lib.message = '歌单是空的';
      return;
    }
    playback.setQueue(songs);
    playback.playIndex(0);
  }

  private addToPlaylist(listId: string): void {
    const song = this.pickerSong;
    const ok = song !== null
      ? playlists.addSongEntity(listId, song)
      : playlists.addSong(listId, this.pickerPath);
    this.lib.message = ok ? '已加入歌单' : '这首歌已经在歌单里了';
    this.pickerPath = '';
    this.pickerSong = null;
  }

  private confirmCreatePlaylist(): void {
    const id = playlists.create(this.newName);
    if (this.pickerPath.length > 0) {
      if (this.pickerSong !== null) {
        playlists.addSongEntity(id, this.pickerSong);
      } else {
        playlists.addSong(id, this.pickerPath);
      }
      this.pickerPath = '';
      this.pickerSong = null;
      this.lib.message = '已加入新歌单';
    }
    this.showCreate = false;
    this.newName = '';
  }

  private async doRemove(song: Song): Promise<void> {
    const playing = song.path === this.player.currentPath;
    library.removeSong(song.path);
    if (playing) {
      this.showPlayer = false;
      this.showQueue = false;
      await playback.clearQueue();
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await persist.saveLibrary(ctx, this.lib.songs);
  }

  private async clearQueue(): Promise<void> {
    this.showQueue = false;
    this.showPlayer = false;
    await playback.clearQueue();
  }

  /** 有没有任何一段已经出内容了 */
  private hasReadyBlock(): boolean {
    for (let i = 0; i < this.online.homeBlocks.length; i++) {
      if (this.online.homeBlocks[i].state === HomeBlockState.READY) {
        return true;
      }
    }
    return false;
  }

  /** 按 3 个一行切歌单，网格用 */
  private playlistChunks(lists: NeteasePlaylist[]): NeteasePlaylist[][] {
    const out: NeteasePlaylist[][] = [];
    let row: NeteasePlaylist[] = [];
    for (let i = 0; i < lists.length; i++) {
      row.push(lists[i]);
      // 列数跟着断点走，宽屏一行铺更多
      if (row.length === this.gridCols) {
        out.push(row);
        row = [];
      }
    }
    if (row.length > 0) {
      out.push(row);
    }
    return out;
  }

  // ─────────────────── 媒体库：收藏 / 下载分区 ───────────────────

  /** 收藏里的分组：按专辑或艺术家，数据来自 favoriteSongs */
  private favGroups(byAlbum: boolean): GroupItem[] {
    const map: Map<string, GroupItem> = new Map();
    for (let i = 0; i < this.favoriteSongs.length; i++) {
      const song = this.favoriteSongs[i];
      let key = byAlbum ? song.album : song.artist;
      if (key.length === 0) {
        key = byAlbum ? '未知专辑' : '未知艺术家';
      }
      const hit = map.get(key);
      if (hit === undefined) {
        const item = new GroupItem();
        item.name = key;
        item.count = 1;
        item.samplePath = song.path;
        item.coverUrl = song.coverUrl;
        item.subtitle = byAlbum ? (song.artist.length > 0 ? song.artist : '') : '';
        map.set(key, item);
      } else {
        hit.count++;
      }
    }
    const out: GroupItem[] = [];
    map.forEach((value: GroupItem) => {
      out.push(value);
    });
    out.sort((a: GroupItem, b: GroupItem) => {
      const an = a.name.toLowerCase();
      const bn = b.name.toLowerCase();
      if (an === bn) {
        return 0;
      }
      return an < bn ? -1 : 1;
    });
    return out;
  }

  private favGroupSongs(byAlbum: boolean, key: string): Song[] {
    return this.favoriteSongs.filter((song: Song) => {
      const name = byAlbum ? song.album : song.artist;
      const normalized = name.length === 0 ? (byAlbum ? '未知专辑' : '未知艺术家') : name;
      return normalized === key;
    });
  }

  /** 下载分区的两个分类 */
  private doneTasks(): DownloadTask[] {
    return this.dl.tasks.filter((t: DownloadTask) => t.status === DownloadStatus.DONE);
  }

  private activeTasks(): DownloadTask[] {
    return this.dl.tasks.filter((t: DownloadTask) => t.status !== DownloadStatus.DONE);
  }

  // ─────────────────── 存储 / 备份 / 外部歌词 ───────────────────

  private currentLocalSong(): Song | null {
    const song = playback.currentSong();
    if (song === null || song.path.length === 0 || song.isRemote()) {
      return null;
    }
    return song;
  }

  private syncLyricFlag(): void {
    const song = this.currentLocalSong();
    this.lyricImported = song !== null && lyric.hasExternal(song.path);
  }

  private lyricImportHint(): string {
    const song = this.currentLocalSong();
    if (song === null) {
      return '先播一首本地歌曲，再来这里导入';
    }
    const mark = this.lyricImported ? '（已导入）' : '';
    return `${song.title}${mark} · 支持 .lrc/.yrc/.ttml`;
  }

  private async measureStorage(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await storage.measure(ctx);
  }

  private confirmClearCache(): void {
    const options: AlertDialogParamWithOptions = {
      title: '清理缓存',
      message: `将清空 ${formatBytes(this.storageState.cache)} 缓存。已下载的歌曲、导入的歌词和曲库都不受影响。`,
      buttons: [
        {
          value: '清理',
          fontColor: '#FF8A8A',
          action: () => {
            this.doClearCache();
          }
        },
        {
          value: '取消',
          action: () => {
          }
        }
      ]
    };
    this.getUIContext().showAlertDialog(options);
  }

  private async doClearCache(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const freed = await storage.clearCache(ctx);
    if (freed >= 0) {
      this.lib.message = `已清理 ${formatBytes(freed)} 缓存`;
    } else {
      this.lib.message = '缓存清理失败，稍后再试';
    }
    await storage.measure(ctx);
  }

  private async pickLyricFile(): Promise<void> {
    const song = this.currentLocalSong();
    if (song === null) {
      this.lib.message = '先播一首本地歌曲，再导入歌词';
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(ctx);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.selectMode = picker.DocumentSelectMode.FILE;
      options.fileSuffixFilters = ['.lrc', '.yrc', '.ttml', '.txt'];
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const ok = await lyric.importExternal(song.path, uris[0]);
      this.syncLyricFlag();
      this.lib.message = ok ? `已导入《${song.title}》的歌词` : '导入失败，文件可能是空的或不支持';
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`选歌词文件失败 ${err.code}: ${err.message}`);
      this.lib.message = `选歌词文件失败 ${err.code}`;
    }
  }

  private removeLyricFile(): void {
    const song = this.currentLocalSong();
    if (song === null) {
      return;
    }
    const options: AlertDialogParamWithOptions = {
      title: '移除导入的歌词',
      message: `《${song.title}》会回到外挂文件或音频内嵌标签。`,
      buttons: [
        {
          value: '移除',
          fontColor: '#FF8A8A',
          action: () => {
            lyric.removeExternal(song.path).then((ok: boolean) => {
              this.syncLyricFlag();
              this.lib.message = ok ? '已移除导入的歌词' : '没有可移除的歌词';
            });
          }
        },
        {
          value: '取消',
          action: () => {
          }
        }
      ]
    };
    this.getUIContext().showAlertDialog(options);
  }

  /** 备份文件名里的时间戳，不用系统 locale，避免出现斜杠 */
  private backupStamp(): string {
    const d = new Date();
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`
      + `-${pad(d.getHours())}${pad(d.getMinutes())}`;
  }

  private async exportBackup(): Promise<void> {
    if (this.backupBusy) {
      return;
    }
    this.backupBusy = true;
    this.backupMsg = '';
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(ctx);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [`memi-backup-${this.backupStamp()}.json`];
      options.fileSuffixChoices = ['.json'];
      const uris: string[] = await documentPicker.save(options);
      if (uris.length === 0) {
        return;
      }
      const summary = await backup.exportTo(uris[0]);
      this.backupMsg = `已导出：${summary}`;
      this.lib.message = '备份已导出';
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`导出备份失败 ${err.code}: ${err.message}`);
      this.backupMsg = `导出失败 ${err.code}`;
    } finally {
      this.backupBusy = false;
    }
  }

  private confirmImportBackup(): void {
    if (this.backupBusy) {
      return;
    }
    const options: AlertDialogParamWithOptions = {
      title: '从备份恢复',
      message: '同 id 的歌单会被覆盖，收藏按路径累加，设置会立即生效。',
      buttons: [
        {
          value: '恢复',
          fontColor: settings.accent(),
          action: () => {
            this.importBackup();
          }
        },
        {
          value: '取消',
          action: () => {
          }
        }
      ]
    };
    this.getUIContext().showAlertDialog(options);
  }

  private async importBackup(): Promise<void> {
    if (this.backupBusy) {
      return;
    }
    this.backupBusy = true;
    this.backupMsg = '';
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(ctx);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.selectMode = picker.DocumentSelectMode.FILE;
      options.fileSuffixFilters = ['.json'];
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const result = await backup.importFrom(uris[0]);
      this.backupMsg = result.ok ? result.message : `恢复失败：${result.message}`;
      if (result.ok) {
        await playlists.reload();
        await this.refreshFavorites();
        library.setSort(settings.state.sortMode);
        this.lib.message = '备份已恢复';
      }
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`导入备份失败 ${err.code}: ${err.message}`);
      this.backupMsg = `恢复失败 ${err.code}`;
    } finally {
      this.backupBusy = false;
    }
  }

  private async pickFiles(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(ctx);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 500;
      options.selectMode = picker.DocumentSelectMode.FILE;
      options.fileSuffixFilters = ['.mp3', '.flac', '.ape', '.wav', '.ogg', '.m4a', '.aac', '.amr', '.opus'];
      const uris: string[] = await documentPicker.select(options);
      Logger.i(`选中 ${uris.length} 个文件`);
      if (uris.length === 0) {
        return;
      }
      await persist.persistUris(uris);
      await library.addFiles(uris);
      await persist.saveLibrary(ctx, this.lib.songs);
      this.startThumbQueue();
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`选文件失败 ${err.code}: ${err.message}`);
      this.lib.message = `选文件失败 ${err.code}: ${err.message}`;
    }
  }
}
