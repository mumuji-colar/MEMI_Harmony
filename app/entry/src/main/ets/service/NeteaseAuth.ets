import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';
import { selfTest } from './NeteaseCrypto';
import { getCookie, setCookie, clearCookie, extractCredential, hasLoginCredential } from './NeteaseSession';
import {
  NeteaseAccount,
  fetchAccount,
  qrCreateSession,
  qrPoll,
  NeteaseQrPoll,
  NeteaseQrSession
} from './NeteaseApi';

const STORE_NAME: string = 'memi_store';
const KEY_COOKIE: string = 'netease_cookie';
/** 扫码有效期约 3 分钟，轮询稍短一点 */
const QR_POLL_INTERVAL: number = 2000;
const QR_MAX_POLLS: number = 90;

/** 扫码界面要展示的阶段 */
export enum QrPhase {
  IDLE = 'idle',
  LOADING = 'loading',
  WAITING = 'waiting',
  SCANNED = 'scanned',
  EXPIRED = 'expired',
  SUCCESS = 'success',
  ERROR = 'error'
}

@ObservedV2
export class NeteaseAuthState {
  @Trace loggedIn: boolean = false;
  @Trace nickname: string = '';
  @Trace avatarUrl: string = '';
  @Trace userId: number = 0;
  /** 0 普通，10 音乐包，11 黑胶 VIP */
  @Trace vipType: number = 0;
  @Trace qrPhase: string = QrPhase.IDLE;
  @Trace qrKey: string = '';
  @Trace qrMessage: string = '';
  /** Cookie 粘贴框 */
  @Trace cookieDraft: string = '';
  @Trace busy: boolean = false;
  /** 通用提示，登录/退出结果都放这儿 */
  @Trace message: string = '';
  /** 每次账号变化 +1，给外部做刷新用 */
  @Trace version: number = 0;

  /** VIP 文案 */
  vipLabel(): string {
    if (this.vipType >= 11) {
      return '黑胶 VIP';
    }
    if (this.vipType >= 10) {
      return '音乐包';
    }
    return '普通用户';
  }
}

/**
 * 网易云账号：扫码登录 / Cookie 导入 / 退出。
 *
 * 只做三件事：拿凭据、存凭据、验证凭据。
 * 凭据本体放在 NeteaseSession 里，接口层每次请求现取，所以登录后无需重建任何客户端。
 */
export class NeteaseAuthService {
  readonly state: NeteaseAuthState = new NeteaseAuthState();

  /** 登录成功回调：界面用它关掉登录页并刷新推荐 */
  onLoginSuccess: (() => void) | null = null;

  private store: preferences.Preferences | null = null;
  private qrTimer: number = -1;
  private qrPolls: number = 0;
  private qrSession: NeteaseQrSession | null = null;

  async init(ctx: common.UIAbilityContext): Promise<void> {
    try {
      const cryptoOk = await selfTest();
      Logger.i(`加解密自检 ${cryptoOk ? '通过' : '失败'}`);
      this.store = await preferences.getPreferences(ctx, STORE_NAME);
      const saved = (await this.store.get(KEY_COOKIE, '')) as string;
      if (saved.length > 0) {
        setCookie(saved);
        Logger.i('已恢复网易云登录凭据');
        await this.refreshAccount(true);
      }
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`读取网易云凭据失败 ${err.code}`);
    }
  }

  /** 扫码二维码内容（scanlogin 链路，必须带 chainId） */
  qrContent(): string {
    const session = this.qrSession;
    if (session === null) {
      return '';
    }
    return session.content;
  }

  /** 拉一次账号信息，silent 用于启动时静默校验 */
  async refreshAccount(silent: boolean = false): Promise<void> {
    if (getCookie().length === 0) {
      this.applyAccount(new NeteaseAccount());
      return;
    }
    if (!silent) {
      this.state.busy = true;
    }
    try {
      const account = await fetchAccount();
      this.applyAccount(account);
      if (!account.loggedIn && !silent) {
        this.state.message = '凭据已失效，请重新登录';
        await this.forgetCookie();
      }
    } finally {
      this.state.busy = false;
    }
  }

  /** 申请二维码并开始轮询 */
  /**
   * 申请二维码并开始轮询。
   * @param deviceToken WebView 里的风控指纹；传空也能出码，但确认后可能停在 802
   * @param seedCookies WebView 里的 cookie（sDeviceId/NMTID），用于 chainId 与会话连续性
   */
  async startQrLogin(deviceToken: string = '', seedCookies: string = ''): Promise<void> {
    this.stopQrLogin();
    this.state.qrPhase = QrPhase.LOADING;
    this.state.qrMessage = '';
    this.state.message = '';
    try {
      const session = await qrCreateSession(deviceToken, seedCookies);
      this.qrSession = session;
      this.state.qrKey = session.key;
      this.state.qrPhase = QrPhase.WAITING;
      this.qrPolls = 0;
      this.qrTimer = setInterval(() => {
        this.pollOnce();
      }, QR_POLL_INTERVAL);
      Logger.i('扫码登录：已获取二维码');
    } catch (e) {
      const err = e as Error;
      this.state.qrPhase = QrPhase.ERROR;
      this.state.qrMessage = err.message;
      Logger.w(`申请二维码失败 ${err.message}`);
    }
  }

  /** 关闭扫码界面，停掉轮询 */
  stopQrLogin(): void {
    if (this.qrTimer >= 0) {
      clearInterval(this.qrTimer);
      this.qrTimer = -1;
    }
    if (this.state.qrPhase !== QrPhase.SUCCESS) {
      this.state.qrPhase = QrPhase.IDLE;
      this.state.qrKey = '';
    }
    this.qrSession = null;
  }

  /** 重新生成一张二维码（过期后点一下） */
  async refreshQr(): Promise<void> {
    await this.startQrLogin();
  }

  private async pollOnce(): Promise<void> {
    if (this.qrTimer < 0 || this.state.qrKey.length === 0) {
      return;
    }
    this.qrPolls++;
    if (this.qrPolls > QR_MAX_POLLS) {
      this.state.qrPhase = QrPhase.EXPIRED;
      this.state.qrMessage = '二维码已过期，请刷新';
      this.stopQrLoginTimerOnly();
      return;
    }
    try {
      const session = this.qrSession;
      if (session === null) {
        this.stopQrLoginTimerOnly();
        return;
      }
      const result: NeteaseQrPoll = await qrPoll(session);
      if (result.code === 800) {
        this.state.qrPhase = QrPhase.EXPIRED;
        this.state.qrMessage = '二维码已过期，请刷新';
        this.stopQrLoginTimerOnly();
        return;
      }
      if (result.code === 802) {
        this.state.qrPhase = QrPhase.SCANNED;
        this.state.qrMessage = '已扫码，请在手机上确认登录';
        return;
      }
      if (result.code === 803) {
        this.stopQrLoginTimerOnly();
        if (result.cookie.length === 0) {
          this.state.qrPhase = QrPhase.ERROR;
          this.state.qrMessage = '扫码确认了，但服务端没下发凭据';
          return;
        }
        await this.commitCookie(result.cookie, true);
        return;
      }
      // 801 继续等
    } catch (e) {
      const err = e as Error;
      Logger.w(`轮询扫码状态失败 ${err.message}`);
    }
  }

  private stopQrLoginTimerOnly(): void {
    if (this.qrTimer >= 0) {
      clearInterval(this.qrTimer);
      this.qrTimer = -1;
    }
  }

  /** Cookie 导入：支持整段 "MUSIC_U=xxx; __csrf=yyy" 或只填 MUSIC_U 的值 */
  async loginWithCookie(raw: string): Promise<boolean> {
    const text = raw.trim();
    if (text.length === 0) {
      this.state.message = '请先粘贴 Cookie';
      return false;
    }
    this.state.busy = true;
    this.state.message = '';
    try {
      // 只给了 MUSIC_U 的值（长度通常 > 50 且没有 "="），补个名字再走
      const normalized = text.indexOf('=') >= 0 ? extractCredential(text) : `MUSIC_U=${text}`;
      if (normalized.length === 0) {
        this.state.message = '没在这段文本里找到 MUSIC_U';
        return false;
      }
      const account = await this.verifyAndStore(normalized);
      if (!account.loggedIn) {
        this.state.message = '凭据无效或已过期';
        return false;
      }
      return true;
    } catch (e) {
      const err = e as Error;
      this.state.message = `校验失败 ${err.message}`;
      return false;
    } finally {
      this.state.busy = false;
    }
  }

  /** 登录成功后的落库，fromQr 决定要不要更新扫码界面状态 */
  private async commitCookie(cookie: string, fromQr: boolean): Promise<void> {
    this.state.busy = true;
    try {
      const account = await this.verifyAndStore(cookie);
      if (!account.loggedIn) {
        this.state.qrPhase = QrPhase.ERROR;
        this.state.qrMessage = '登录成功但校验账号失败';
        return;
      }
      if (fromQr) {
        this.state.qrPhase = QrPhase.SUCCESS;
        this.state.qrMessage = '登录成功';
        this.state.qrKey = '';
      }
      this.state.cookieDraft = '';
      const cb = this.onLoginSuccess;
      if (cb !== null) {
        setTimeout(() => {
          cb();
        }, 0);
      }
    } finally {
      this.state.busy = false;
    }
  }

  /** 写入会话 → 存盘 → 查账号 → 通知界面 */
  private async verifyAndStore(cookie: string): Promise<NeteaseAccount> {
    setCookie(cookie);
    const account = await fetchAccount();
    if (!account.loggedIn) {
      // 安卓版的做法是「尽力校验」：只要确实拿到了 MUSIC_U 就先留着，
      // 账号接口偶发失败不该把刚拿到的凭据丢掉。
      if (!hasLoginCredential(cookie)) {
        await this.forgetCookie();
        return account;
      }
      Logger.w('已拿到 MUSIC_U，但账号信息读取失败，先保留凭据');
      this.state.loggedIn = true;
      this.state.nickname = this.state.nickname.length > 0 ? this.state.nickname : '网易云用户';
      this.state.message = '已保存凭据，账号信息暂时读取失败';
      await this.persist(cookie);
      this.state.version++;
      return account;
    }
    this.applyAccount(account);
    await this.persist(cookie);
    this.state.message = `已登录：${account.nickname}`;
    this.state.version++;
    Logger.i(`网易云登录成功 ${account.nickname} vip=${account.vipType}`);
    return account;
  }

  async logout(): Promise<void> {
    await this.forgetCookie();
    this.applyAccount(new NeteaseAccount());
    this.state.message = '已退出登录';
    this.state.qrPhase = QrPhase.IDLE;
    this.state.version++;
    Logger.i('已退出网易云登录');
  }

  private applyAccount(account: NeteaseAccount): void {
    this.state.loggedIn = account.loggedIn;
    this.state.nickname = account.nickname;
    this.state.avatarUrl = account.avatarUrl;
    this.state.userId = account.userId;
    this.state.vipType = account.vipType;
  }

  private async forgetCookie(): Promise<void> {
    clearCookie();
    try {
      if (this.store !== null) {
        await this.store.delete(KEY_COOKIE);
        await this.store.flush();
      }
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`清除凭据失败 ${err.code}`);
    }
  }

  private async persist(cookie: string): Promise<void> {
    try {
      if (this.store !== null) {
        await this.store.put(KEY_COOKIE, cookie);
        await this.store.flush();
      }
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`保存凭据失败 ${err.code}`);
    }
  }

}

export const neteaseAuth: NeteaseAuthService = new NeteaseAuthService();
