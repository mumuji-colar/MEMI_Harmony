import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Song } from '../model/Song';
import { Logger } from '../common/Logger';
import { getCookie, setCookie, extractCredential, parseCookiePairs } from './NeteaseSession';
import { eapiParams, weapiParams } from './NeteaseCrypto';

/**
 * 网易云音乐接口层。
 *
 * 两条通道并存：
 * 1. 明文 api（/api/...）：搜索、歌词、歌单、专辑都用它，匿名即可，够快；
 * 2. eapi（/eapi/...，AES-128-ECB 加密）：播放地址要拿无损/高码率必须走它，
 *    因为 /api/song/enhance/player/url 只认 br，最高 320k。
 * 登录态通过 Cookie 头带进去，没登录时自动降级成匿名。
 */

const BASE: string = 'https://music.163.com';
const UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/* ───────────────────────── JSON 结构 ───────────────────────── */

interface NsArtistJson {
  id?: number;
  name?: string | null;
}

interface NsAlbumJson {
  id?: number;
  name?: string | null;
  picUrl?: string | null;
  artist?: NsArtistJson | null;
  artists?: NsArtistJson[] | null;
}

interface NsSongJson {
  id?: number;
  name?: string | null;
  fee?: number;
  duration?: number;
  dt?: number;
  artists?: NsArtistJson[] | null;
  ar?: NsArtistJson[] | null;
  album?: NsAlbumJson | null;
  al?: NsAlbumJson | null;
}

interface NsCreatorJson {
  nickname?: string | null;
  userId?: number;
}

interface NsPlaylistJson {
  id?: number;
  name?: string | null;
  coverImgUrl?: string | null;
  picUrl?: string | null;
  playCount?: number;
  trackCount?: number;
  description?: string | null;
  creator?: NsCreatorJson | null;
  tracks?: NsSongJson[] | null;
  updateTime?: number;
}

interface NsSearchResultJson {
  songs?: NsSongJson[] | null;
  songCount?: number;
  playlists?: NsPlaylistJson[] | null;
  playlistCount?: number;
  albums?: NsAlbumJson[] | null;
  albumCount?: number;
}

interface NsSearchRespJson {
  code?: number;
  result?: NsSearchResultJson;
}

interface NsUrlItemJson {
  id?: number;
  url?: string | null;
  br?: number;
  size?: number;
  type?: string | null;
  code?: number;
  fee?: number;
  level?: string | null;
  freeTrialInfo?: Object | null;
}

interface NsUrlRespJson {
  code?: number;
  data?: NsUrlItemJson[] | null;
}

interface NsLyricBodyJson {
  lyric?: string | null;
}

interface NsLyricRespJson {
  code?: number;
  lrc?: NsLyricBodyJson | null;
  tlyric?: NsLyricBodyJson | null;
  yrc?: NsLyricBodyJson | null;
  ytlrc?: NsLyricBodyJson | null;
  romalrc?: NsLyricBodyJson | null;
}

interface NsPlaylistRespJson {
  code?: number;
  playlist?: NsPlaylistJson | null;
}

interface NsPersonalizedRespJson {
  code?: number;
  result?: NsPlaylistJson[] | null;
}

interface NsTopListRespJson {
  code?: number;
  playlists?: NsPlaylistJson[] | null;
  more?: boolean;
}

interface NsAlbumRespJson {
  code?: number;
  album?: NsAlbumJson | null;
  songs?: NsSongJson[] | null;
}

/** v3/song/detail 的顶层就是 songs，和专辑接口同形 */
interface NsDetailRespJson {
  code?: number;
  songs?: NsSongJson[];
}

/** 每日推荐：data.dailySongs */
interface NsDailyDataJson {
  dailySongs?: NsSongJson[] | null;
}

interface NsDailyRespJson {
  code?: number;
  data?: NsDailyDataJson | null;
}

/** 私人 FM：data 直接就是歌曲数组 */
interface NsRadioRespJson {
  code?: number;
  data?: NsSongJson[] | null;
}

/** 推荐新歌：result[] 里每项可能是完整歌曲，也可能套一层 song */
interface NsNewSongItemJson {
  id?: number;
  name?: string | null;
  picUrl?: string | null;
  duration?: number;
  album?: NsAlbumJson | null;
  artists?: NsArtistJson[] | null;
  song?: NsSongJson | null;
}

interface NsNewSongRespJson {
  code?: number;
  result?: NsNewSongItemJson[] | null;
}

/* ───────────────────────── 对外模型 ───────────────────────── */

/** 在线歌单（搜索结果、推荐、榜单共用） */
export class NeteasePlaylist {
  id: number = 0;
  name: string = '';
  coverUrl: string = '';
  playCount: number = 0;
  trackCount: number = 0;
  creator: string = '';
  description: string = '';
  /** 专辑发行年份，歌单为空 */
  year: string = '';
}

/** 播放地址解析结果 */
export class NeteasePlayUrl {
  /** 可直接交给 AVPlayer 的 https 地址，空串表示拿不到 */
  url: string = '';
  /** 码率，单位 bps */
  br: number = 0;
  /** 容器格式，如 mp3 / flac */
  type: string = '';
  /** 文件字节数 */
  size: number = 0;
  /** 接口返回的 data[0].code，200 正常，-110 表示版权受限 */
  code: number = 0;
  /** 音质档位，如 standard / exhigh */
  level: string = '';
  /** 实际音源：netease / bili。换源后列表与播放页会标出来 */
  source: string = 'netease';
  /** 服务端只给试听片段（30 秒）时为 true，调用方应当尝试换源 */
  freeTrial: boolean = false;

  ok(): boolean {
    return this.url.length > 0;
  }

  /** 列表副标题用的中文音质描述 */
  qualityLabel(): string {
    if (this.url.length === 0) {
      return '';
    }
    const kbps = this.br > 0 ? Math.round(this.br / 1000) : 0;
    const fmt = this.type.length > 0 ? this.type.toUpperCase() : '';
    if (kbps <= 0) {
      return fmt;
    }
    const main = fmt.length > 0 ? `${kbps}k ${fmt}` : `${kbps}k`;
    return this.source === 'bili' ? `${main} · B站` : main;
  }
}

/** 歌词包，lrc 与 yrc 只会有一个为主 */
export class NeteaseLyric {
  lrc: string = '';
  /** 逐字歌词（YRC），有就能做逐字着色 */
  yrc: string = '';
  /** 翻译 */
  translation: string = '';
  /** 逐字翻译 */
  yrcTranslation: string = '';
}

/* ───────────────────────── HTTP ───────────────────────── */

function headers(): Record<string, string> {
  const h: Record<string, string> = {};
  h['User-Agent'] = UA;
  h['Referer'] = 'https://music.163.com';
  h['Accept'] = '*/*';
  h['Accept-Language'] = 'zh-CN,zh-Hans;q=0.9';
  const credential = getCookie();
  const session = qrCookieHeader();
  if (credential.length > 0 && session.length > 0) {
    h['Cookie'] = `${credential}; ${session}`;
  } else if (credential.length > 0) {
    h['Cookie'] = credential;
  } else if (session.length > 0) {
    h['Cookie'] = session;
  }
  return h;
}

/** 一次 HTTP 的完整结果，登录流程要读 Set-Cookie，所以不能只回字符串 */
export class NeteaseHttpResult {
  text: string = '';
  /** 响应头里的 set-cookie，可能有多条 */
  cookies: string[] = [];
  /** 网易云登录成功会在响应头回一个刷新令牌，等价于 MUSIC_U */
  refreshToken: string = '';
}

/**
 * 读响应头。
 * 鸿蒙的 header 是个普通对象，键名大小写不保证（HTTP/2 常见小写，也有实现给原样），
 * 所以这里按小写比对，别直接用 header['set-cookie'] 去撞运气。
 */
function readHeader(header: Object, name: string): string {
  const map = header as Record<string, Object>;
  const want = name.toLowerCase();
  const keys = Object.keys(map);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].toLowerCase() !== want) {
      continue;
    }
    const raw = map[keys[i]];
    if (raw === undefined || raw === null) {
      return '';
    }
    if (typeof raw === 'string') {
      return raw as string;
    }
    if (Array.isArray(raw)) {
      const list = raw as string[];
      return list.length > 0 ? list.join('; ') : '';
    }
    return `${raw}`;
  }
  return '';
}

function readSetCookies(header: Object): string[] {
  const out: string[] = [];
  const raw = readHeader(header, 'set-cookie');
  if (raw.length > 0) {
    out.push(raw);
  }
  return out;
}

/**
 * 收集这次响应里服务端下发的 cookie。
 * 首选 HttpResponse.cookies——这是文档里明说的「服务端原始 cookie」，
 * header 里的 set-cookie 在部分实现里会被丢掉或合并，光靠 header 会漏。
 */
function collectCookies(resp: http.HttpResponse): string[] {
  const out: string[] = [];
  const direct = resp.cookies;
  if (direct !== undefined && direct !== null && direct.length > 0) {
    out.push(direct);
  }
  const fromHeader = readSetCookies(resp.header);
  for (let i = 0; i < fromHeader.length; i++) {
    out.push(fromHeader[i]);
  }
  return out;
}

async function requestRaw(path: string, method: http.RequestMethod, body: string = '',
  host: string = BASE, extra: Record<string, string> | null = null): Promise<NeteaseHttpResult> {
  const req = http.createHttp();
  try {
    const h: Record<string, string> = headers();
    if (body.length > 0) {
      h['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    if (extra !== null) {
      const keys = Object.keys(extra);
      for (let i = 0; i < keys.length; i++) {
        h[keys[i]] = extra[keys[i]];
      }
    }
    const options: http.HttpRequestOptions = {
      method: method,
      header: h,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 10000,
      readTimeout: 15000,
      usingCache: false
    };
    if (body.length > 0) {
      options.extraData = body;
    }
    const resp = await req.request(`${host}${path}`, options);
    if (resp.responseCode !== 200) {
      throw new Error(`HTTP ${resp.responseCode}`);
    }
    const result = new NeteaseHttpResult();
    result.text = resp.result as string;
    result.cookies = collectCookies(resp);
    absorbQrCookies(result.cookies);
    result.refreshToken = readHeader(resp.header, 'x-refresh-token');
    if (result.cookies.length > 0) {
      Logger.i(`响应含 cookie：${result.cookies.join(' | ').substring(0, 120)}`);
    }
    return result;
  } finally {
    req.destroy();
  }
}

const EAPI_HOST: string = 'https://interface.music.163.com';

async function getText(path: string): Promise<string> {
  const result = await requestRaw(path, http.RequestMethod.GET);
  return result.text;
}

/** eapi 通道：把载荷加密后以表单 params 提交，返回完整结果（登录要读 Set-Cookie） */
async function eapiRequest(path: string, payload: Record<string, string>): Promise<NeteaseHttpResult> {
  const params = await eapiParams(path, payload);
  const body = `params=${encodeURIComponent(params)}`;
  return requestRaw(path, http.RequestMethod.POST, body, EAPI_HOST);
}

async function eapiText(path: string, payload: Record<string, string>): Promise<string> {
  const result = await eapiRequest(path, payload);
  return result.text;
}

/** weapi 通道：与官方网页/安卓客户端一致，params + encSecKey 两个字段 */
async function weapiRequest(path: string, payload: Record<string, Object>,
  extra: Record<string, string> | null = null): Promise<NeteaseHttpResult> {
  const encrypted = await weapiParams(payload);
  const body = `params=${encodeURIComponent(encrypted['params'])}`
    + `&encSecKey=${encodeURIComponent(encrypted['encSecKey'])}`;
  return requestRaw(path, http.RequestMethod.POST, body, BASE, extra);
}

/** 网易云给的是 http 直链，鸿蒙默认禁明文，统一升级到 https（CDN 两个都支持） */
function toHttps(url: string): string {
  if (url.startsWith('http://')) {
    return `https://${url.substring(7)}`;
  }
  return url;
}

/* ───────────────────────── 解析 ───────────────────────── */

/**
 * 网易云会把大量字段显式返回成 null（VIP 曲目的 url、没有封面时的 picUrl 等）。
 * ArkTS 里 null 和 undefined 是两回事，直接取 .length 会抛
 * "Cannot read property length of null"，所以统一在这里收口。
 */
function cleanStr(v: string | null | undefined): string {
  if (v === undefined || v === null) {
    return '';
  }
  return v;
}

function artistsOf(json: NsSongJson): string {
  const list = json.ar !== undefined && json.ar !== null ? json.ar : json.artists;
  if (list === undefined || list === null) {
    return '';
  }
  const names: string[] = [];
  for (let i = 0; i < list.length; i++) {
    const name = cleanStr(list[i].name);
    if (name.length > 0) {
      names.push(name);
    }
  }
  return names.join(' / ');
}

function albumOf(json: NsSongJson): NsAlbumJson | null {
  const al = json.al !== undefined && json.al !== null ? json.al : json.album;
  return al === undefined ? null : al;
}

/**
 * 把接口返回的单曲转成内部 Song。
 * 网易云的 ID 是 long，本地曲库用的是文件路径，两者用 path 前缀区分，
 * 这样队列、收藏、统计这些按 path 索引的逻辑完全不用改。
 */
function toSong(json: NsSongJson): Song | null {
  const id = json.id !== undefined ? json.id : 0;
  const name = cleanStr(json.name);
  if (id <= 0 || name.length === 0) {
    return null;
  }
  const album = albumOf(json);
  const song = new Song(`netease://${id}`, '');
  song.source = 'netease';
  song.remoteId = id;
  song.title = name;
  song.artist = artistsOf(json);
  const ar = json.ar !== undefined && json.ar !== null ? json.ar
    : (json.artists !== undefined && json.artists !== null ? json.artists : null);
  if (ar !== null && ar.length > 0 && ar[0].id !== undefined) {
    song.artistId = ar[0].id;
  }
  song.album = album === null ? '' : cleanStr(album.name);
  const dur = json.dt !== undefined ? json.dt : json.duration;
  song.durationMs = dur !== undefined ? dur : 0;
  if (album !== null) {
    song.coverUrl = toHttps(cleanStr(album.picUrl));
  }
  return song;
}

function toPlaylist(json: NsPlaylistJson): NeteasePlaylist {
  const p = new NeteasePlaylist();
  p.id = json.id !== undefined ? json.id : 0;
  p.name = cleanStr(json.name);
  const coverImg = cleanStr(json.coverImgUrl);
  p.coverUrl = toHttps(coverImg.length > 0 ? coverImg : cleanStr(json.picUrl));
  p.playCount = json.playCount !== undefined ? json.playCount : 0;
  p.trackCount = json.trackCount !== undefined ? json.trackCount : 0;
  const creator = json.creator;
  p.creator = creator === undefined || creator === null ? '' : cleanStr(creator.nickname);
  p.description = cleanStr(json.description);
  return p;
}

/* ───────────────────────── 业务接口 ───────────────────────── */

/** 搜索单曲 */
export async function searchSongs(keyword: string, limit: number, offset: number): Promise<Song[]> {
  const path = `/api/search/get/web?s=${encodeURIComponent(keyword)}&type=1&limit=${limit}&offset=${offset}`;
  const text = await getText(path);
  const json = JSON.parse(text) as NsSearchRespJson;
  if (json.code !== 200 || json.result === undefined || json.result === null) {
    return [];
  }
  const list = json.result.songs;
  if (list === undefined || list === null) {
    return [];
  }
  const songs: Song[] = [];
  for (let i = 0; i < list.length; i++) {
    const s = toSong(list[i]);
    if (s !== null) {
      songs.push(s);
    }
  }
  return songs;
}

/** 搜索歌单 */
export async function searchPlaylists(keyword: string, limit: number, offset: number): Promise<NeteasePlaylist[]> {
  const path = `/api/search/get/web?s=${encodeURIComponent(keyword)}&type=1000&limit=${limit}&offset=${offset}`;
  const text = await getText(path);
  const json = JSON.parse(text) as NsSearchRespJson;
  if (json.code !== 200 || json.result === undefined || json.result === null) {
    return [];
  }
  const list = json.result.playlists;
  if (list === undefined || list === null) {
    return [];
  }
  const out: NeteasePlaylist[] = [];
  for (let i = 0; i < list.length; i++) {
    out.push(toPlaylist(list[i]));
  }
  return out;
}

/** 搜索专辑，返回专辑里的歌（专辑本身的名字取第一首的 album 字段） */
export async function searchAlbums(keyword: string, limit: number, offset: number): Promise<NeteasePlaylist[]> {
  const path = `/api/search/get/web?s=${encodeURIComponent(keyword)}&type=10&limit=${limit}&offset=${offset}`;
  const text = await getText(path);
  const json = JSON.parse(text) as NsSearchRespJson;
  if (json.code !== 200 || json.result === undefined || json.result === null) {
    return [];
  }
  const list = json.result.albums;
  if (list === undefined || list === null) {
    return [];
  }
  const out: NeteasePlaylist[] = [];
  for (let i = 0; i < list.length; i++) {
    const a = list[i];
    const p = new NeteasePlaylist();
    p.id = a.id !== undefined ? a.id : 0;
    p.name = cleanStr(a.name);
    p.coverUrl = toHttps(cleanStr(a.picUrl));
    const ar = a.artists !== undefined && a.artists !== null ? a.artists
      : (a.artist !== undefined && a.artist !== null ? [a.artist] : []);
    const names: string[] = [];
    for (let j = 0; j < ar.length; j++) {
      const n = cleanStr(ar[j].name);
      if (n.length > 0) {
        names.push(n);
      }
    }
    p.creator = names.join(' / ');
    out.push(p);
  }
  return out;
}

function lyricField(body: NsLyricBodyJson | null | undefined): string {
  if (body === undefined || body === null) {
    return '';
  }
  return cleanStr(body.lyric);
}

/**
 * 解析播放地址。
 * 请求 320k，服务端按版权给到什么就是什么；VIP 曲目 url 为空。
 */
function parseUrlResponse(text: string): NeteasePlayUrl {
  const result = new NeteasePlayUrl();
  const json = JSON.parse(text) as NsUrlRespJson;
  if (json.data === undefined || json.data === null || json.data.length === 0) {
    return result;
  }
  const d = json.data[0];
  result.code = d.code !== undefined ? d.code : 0;
  result.br = d.br !== undefined ? d.br : 0;
  result.type = cleanStr(d.type);
  result.size = d.size !== undefined ? d.size : 0;
  result.level = cleanStr(d.level);
  result.freeTrial = d.freeTrialInfo !== undefined && d.freeTrialInfo !== null;
  const rawUrl = cleanStr(d.url);
  if (rawUrl.length > 0) {
    result.url = toHttps(rawUrl);
  }
  return result;
}

/**
 * 解析播放地址。
 * 优先走 eapi v1：它按 level 给码率，登录且有会员时能拿到无损/母带；
 * 匿名或无权限会由服务端自动降档，不会报错。
 * eapi 整条链路出问题（加密/网络）时退回明文 v0，保证还能播 320k。
 */
export async function resolvePlayUrl(songId: number, level: string = 'exhigh'): Promise<NeteasePlayUrl> {
  try {
    const payload: Record<string, string> = {};
    payload['ids'] = `[${songId}]`;
    payload['level'] = level;
    payload['encodeType'] = 'flac';
    const text = await eapiText('/eapi/song/enhance/player/url/v1', payload);
    const parsed = parseUrlResponse(text);
    Logger.i(`eapi 播放地址 level=${level} -> code=${parsed.code} ${parsed.qualityLabel()}`);
    // code 200=正常，-110=版权/会员受限，都是明确结论，不用再试明文
    if (parsed.code === 200 || parsed.code === -110) {
      return parsed;
    }
    Logger.w(`eapi 播放地址返回异常 code=${parsed.code}，退回明文接口`);
  } catch (e) {
    Logger.w(`eapi 播放地址失败 ${(e as Error).message}，退回明文接口`);
  }
  const text = await getText(`/api/song/enhance/player/url?ids=[${songId}]&br=320000`);
  return parseUrlResponse(text);
}

/* ───────────────────────── 账号 / 登录 ───────────────────────── */

interface NsAccountJson {
  id?: number;
  vipType?: number;
}

interface NsProfileJson {
  userId?: number;
  nickname?: string | null;
  avatarUrl?: string | null;
  vipType?: number;
}

interface NsAccountRespJson {
  code?: number;
  account?: NsAccountJson | null;
  profile?: NsProfileJson | null;
}

interface NsQrKeyRespJson {
  code?: number;
  unikey?: string | null;
  message?: string | null;
}

interface NsQrPollRespJson {
  code?: number;
  message?: string | null;
  msg?: string | null;
}

/** 账号信息 */
export class NeteaseAccount {
  loggedIn: boolean = false;
  userId: number = 0;
  nickname: string = '';
  avatarUrl: string = '';
  /** 0 普通，10 音乐包，11 黑胶 VIP */
  vipType: number = 0;
}

/** 查询当前 Cookie 对应的账号，未登录返回 loggedIn=false */
export async function fetchAccount(): Promise<NeteaseAccount> {
  const out = new NeteaseAccount();
  let text = '';
  try {
    const payload: Record<string, Object> = {};
    text = (await weapiRequest('/weapi/w/nuser/account/get', payload)).text;
  } catch (e) {
    Logger.w(`weapi 查账号失败，退回明文：${(e as Error).message}`);
  }
  if (text.length === 0) {
    try {
      text = await getText('/api/nuser/account/get');
    } catch (e) {
      Logger.w(`查账号失败 ${(e as Error).message}`);
      return out;
    }
  }
  try {
    const json = JSON.parse(text) as NsAccountRespJson;
    if (json.code !== 200 || json.profile === undefined || json.profile === null) {
      return out;
    }
    const p = json.profile;
    out.loggedIn = true;
    out.userId = p.userId !== undefined ? p.userId : 0;
    out.nickname = cleanStr(p.nickname);
    out.avatarUrl = toHttps(cleanStr(p.avatarUrl));
    const fromProfile = p.vipType !== undefined ? p.vipType : 0;
    const fromAccount = json.account !== undefined && json.account !== null && json.account.vipType !== undefined
      ? json.account.vipType : 0;
    out.vipType = Math.max(fromProfile, fromAccount);
    return out;
  } catch (e) {
    Logger.w(`查询账号失败 ${(e as Error).message}`);
    return out;
  }
}

/**
 * 扫码会话。
 *
 * 二维码内容不能用老的 `login?codekey=`——新版 App 扫到会当普通网页打开，
 * 表现就是「提示登录 web 端、扫完没反应」。要带 chainId 走 scanlogin 链路，
 * 轮询时把同一个 chainId 回传，服务端才认这是同一次登录。
 */
export class NeteaseQrSession {
  key: string = '';
  chainId: string = '';
  content: string = '';
  /** 网页风控指纹，轮询时必须原样回传 */
  ydDeviceToken: string = '';
}

/**
 * 会话级 cookie 罐。
 * unikey 会下发 NMTID，登录请求带上它更接近真实浏览器；
 * 之后服务端下发的其它 cookie 也一并留着，统一随请求发出。
 */
let sessionCookies: Record<string, string> = {};

/** 凭据类 cookie 由 NeteaseSession 单独管理，这里不重复带 */
function isCredentialKey(name: string): boolean {
  return name === 'MUSIC_U' || name === '__csrf' || name === 'MUSIC_A';
}

function qrCookieHeader(): string {
  const parts: string[] = [];
  const keys = Object.keys(sessionCookies);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    if (isCredentialKey(key)) {
      continue;
    }
    parts.push(`${key}=${sessionCookies[key]}`);
  }
  return parts.join('; ');
}

function absorbQrCookies(cookies: string[]): void {
  for (let i = 0; i < cookies.length; i++) {
    // 两种格式（name=value / NetScape 制表符）由 parseCookiePairs 统一处理
    const pairs = parseCookiePairs(cookies[i]);
    const names = Object.keys(pairs);
    for (let j = 0; j < names.length; j++) {
      sessionCookies[names[j]] = pairs[names[j]];
    }
  }
}

/**
 * 用 WebView 里的 cookie 给会话罐打底。
 * sDeviceId / NMTID 这些是风控链路的连续性凭据，缺了服务端就只认「已扫码」不认「已确认」。
 */
function seedSessionCookies(raw: string): void {
  if (raw.length === 0) {
    return;
  }
  const pairs = parseCookiePairs(raw);
  const names = Object.keys(pairs);
  for (let i = 0; i < names.length; i++) {
    sessionCookies[names[i]] = pairs[names[i]];
  }
  Logger.i(`扫码会话 cookie 打底：${names.join(',')}`);
}

function deviceIdFrom(raw: string): string {
  if (raw.length === 0) {
    return '';
  }
  const pairs = parseCookiePairs(raw);
  const id = pairs['sDeviceId'];
  return id === undefined ? '' : id;
}

/** chainId 里的设备段必须与 sDeviceId 一致，安卓版就是这么拼的 */
function loginChainId(deviceId: string): string {
  const device = deviceId.length > 0 ? deviceId : `unknown-${Math.floor(Math.random() * 1000000)}`;
  return `v1_${device}_web_login_${Date.now()}`;
}

/** 扫码请求要带网页客户端的身份线索，服务端才会当成一次真实的网页登录 */
function qrHeaders(chainId: string): Record<string, string> {
  const h: Record<string, string> = {};
  h['Origin'] = 'https://music.163.com';
  h['x-os'] = 'web';
  h['x-channelsource'] = 'undefined';
  h['nm-gcore-status'] = '1';
  h['Cache-Control'] = 'no-cache';
  h['Pragma'] = 'no-cache';
  h['x-loginmethod'] = 'QrCode';
  if (chainId.length > 0) {
    h['x-login-chain-id'] = chainId;
  }
  return h;
}

/**
 * 申请扫码会话。
 * @param deviceToken WebView 里 createNEFingerprint 拿到的风控指纹，可为空
 * @param seedCookies WebView 里的 cookie 串，用来补齐 sDeviceId / NMTID
 */
export async function qrCreateSession(deviceToken: string = '',
  seedCookies: string = ''): Promise<NeteaseQrSession> {
  seedSessionCookies(seedCookies);
  const payload: Record<string, Object> = {};
  payload['type'] = 1;
  payload['noCheckToken'] = true;
  let result: NeteaseHttpResult;
  try {
    result = await weapiRequest('/weapi/login/qrcode/unikey', payload, qrHeaders(''));
  } catch (e) {
    Logger.w(`weapi 申请二维码失败，退回 eapi：${(e as Error).message}`);
    const eapiPayload: Record<string, string> = {};
    eapiPayload['type'] = '1';
    eapiPayload['noCheckToken'] = 'true';
    result = await eapiRequest('/eapi/login/qrcode/unikey', eapiPayload);
  }
  absorbQrCookies(result.cookies);
  const json = JSON.parse(result.text) as NsQrKeyRespJson;
  const key = cleanStr(json.unikey);
  if (json.code !== 200 || key.length === 0) {
    throw new Error(cleanStr(json.message).length > 0 ? cleanStr(json.message) : `申请二维码失败 code=${json.code}`);
  }
  Logger.i(`扫码 cookie：${qrCookieHeader().length > 0 ? qrCookieHeader() : '（空）'}`);
  const session = new NeteaseQrSession();
  session.key = key;
  session.chainId = loginChainId(deviceIdFrom(seedCookies));
  session.ydDeviceToken = deviceToken;
  session.content = `https://music.163.com/st/platform/scanlogin?codekey=${encodeURIComponent(key)}`
    + `&chainId=${encodeURIComponent(session.chainId)}&hdw_device=web&hdw_appid=web&hitExp=1`;
  Logger.i(`扫码会话已创建 key=${key.substring(0, 8)}… chain=${session.chainId.substring(0, 12)}… `
    + `ydToken=${deviceToken.length} cookie=${seedCookies.length}`);
  return session;
}

/**
 * 把响应里的 cookie 拼成请求头格式。
 * 登录成功时 MUSIC_U 可能只出现在 NetScape 里，x-refresh-token 是它的兜底来源。
 */
function cookieFrom(cookies: string[], refreshToken: string): string {
  const parts: string[] = [];
  for (let i = 0; i < cookies.length; i++) {
    parts.push(cookies[i]);
  }
  const raw = parts.join('\n');
  let cookie = extractCredential(raw);
  if (cookie.indexOf('MUSIC_U=') < 0 && refreshToken.length > 0) {
    cookie = cookie.length > 0 ? `MUSIC_U=${refreshToken}; ${cookie}` : `MUSIC_U=${refreshToken}`;
  }
  return cookie;
}

export class NeteaseQrPoll {
  /** 800 过期 801 待扫码 802 待确认 803 成功 */
  code: number = 0;
  message: string = '';
  /** 登录成功时带出来的 Cookie 串 */
  cookie: string = '';
}

/** 轮询扫码状态 */
export async function qrPoll(session: NeteaseQrSession): Promise<NeteaseQrPoll> {
  const out = new NeteaseQrPoll();
  const payload: Record<string, Object> = {};
  payload['type'] = 1;
  payload['noCheckToken'] = true;
  payload['key'] = session.key;
  payload['ydDeviceToken'] = session.ydDeviceToken;
  const result = await weapiRequest('/weapi/login/qrcode/client/login', payload,
    qrHeaders(session.chainId));
  absorbQrCookies(result.cookies);
  const json = JSON.parse(result.text) as NsQrPollRespJson;
  out.code = json.code !== undefined ? json.code : 0;
  const msg = cleanStr(json.message);
  out.message = msg.length > 0 ? msg : cleanStr(json.msg);
  if (out.code === 803) {
    out.cookie = cookieFrom(result.cookies, result.refreshToken);
  }
  return out;
}

/** 校验一段粘贴进来的 Cookie 是否真的能登录，返回账号信息 */
export async function verifyCookie(raw: string): Promise<NeteaseAccount> {
  const before = getCookie();
  setCookie(raw);
  try {
    const account = await fetchAccount();
    if (!account.loggedIn) {
      setCookie(before);
    }
    return account;
  } catch (e) {
    setCookie(before);
    throw e as Error;
  }
}

/** 取歌词，lv=-1 表示要逐字（YRC） */
export async function fetchLyric(songId: number): Promise<NeteaseLyric> {
  const out = new NeteaseLyric();
  const path = `/api/song/lyric?id=${songId}&lv=-1&kv=-1&tv=-1&yv=-1&ytv=-1&yrv=-1`;
  const text = await getText(path);
  const json = JSON.parse(text) as NsLyricRespJson;
  if (json.code !== 200) {
    return out;
  }
  out.lrc = lyricField(json.lrc);
  out.yrc = lyricField(json.yrc);
  out.translation = lyricField(json.tlyric);
  out.yrcTranslation = lyricField(json.ytlrc);
  return out;
}

/** 歌单详情（含曲目，最多 1000 首） */
export async function fetchPlaylistDetail(playlistId: number): Promise<Song[]> {
  const path = `/api/v6/playlist/detail?id=${playlistId}&n=1000&s=8`;
  const text = await getText(path);
  const json = JSON.parse(text) as NsPlaylistRespJson;
  if (json.code !== 200 || json.playlist === undefined || json.playlist === null) {
    return [];
  }
  const list = json.playlist.tracks;
  if (list === undefined || list === null) {
    return [];
  }
  const songs: Song[] = [];
  for (let i = 0; i < list.length; i++) {
    const s = toSong(list[i]);
    if (s !== null) {
      songs.push(s);
    }
  }
  return songs;
}

/** 专辑详情（含曲目） */
export async function fetchAlbumSongs(albumId: number): Promise<Song[]> {
  const path = `/api/v1/album/${albumId}`;
  const text = await getText(path);
  const json = JSON.parse(text) as NsAlbumRespJson;
  const list = json.songs;
  if (json.code !== 200 || list === undefined || list === null) {
    return [];
  }
  const songs: Song[] = [];
  for (let i = 0; i < list.length; i++) {
    const s = toSong(list[i]);
    if (s !== null) {
      songs.push(s);
    }
  }
  return songs;
}

/** 推荐歌单（首页默认内容） */
export async function fetchPersonalized(limit: number = 12): Promise<NeteasePlaylist[]> {
  const path = `/api/personalized/playlist?limit=${limit}`;
  const text = await getText(path);
  const json = JSON.parse(text) as NsPersonalizedRespJson;
  if (json.code !== 200 || json.result === undefined || json.result === null) {
    return [];
  }
  const out: NeteasePlaylist[] = [];
  for (let i = 0; i < json.result.length; i++) {
    out.push(toPlaylist(json.result[i]));
  }
  return out;
}

/** 热门歌单榜 */
/** 歌单广场的请求节流：这个接口连续打太快会回 405 */
let lastPlaylistListAt: number = 0;
let playlistListBlockedUntil: number = 0;
const PLAYLIST_LIST_GAP: number = 1100;

function sleepMs(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/** 歌单广场：按分类 + 热度翻页，探索页的无限信息流靠它 */
export async function fetchPlaylistList(cat: string, limit: number = 48,
  offset: number = 0, order: string = 'hot'): Promise<NeteasePlaylist[]> {
  const now = Date.now();
  if (now < playlistListBlockedUntil) {
    throw new Error('歌单广场限流中');
  }
  // 两次请求至少隔半秒，避免被判定成爬虫
  const wait = lastPlaylistListAt + PLAYLIST_LIST_GAP - now;
  if (wait > 0) {
    await sleepMs(wait);
  }
  lastPlaylistListAt = Date.now();

  try {
    const path = `/api/playlist/list?cat=${encodeURIComponent(cat)}&order=${order}`
      + `&limit=${limit}&offset=${offset}&total=true`;
    const text = await getText(path);
    const json = JSON.parse(text) as NsTopListRespJson;
    // 限流时网易云仍然回 200，但 body 里带错误码；这种要当失败抛出去，
    // 否则调用方会当成「这个分类翻到底了」，把信息流误判成到底
    if (json.code !== 200) {
      throw new Error(`歌单广场返回 ${json.code}`);
    }
    if (json.playlists === undefined || json.playlists === null) {
      return [];
    }
    const out: NeteasePlaylist[] = [];
    for (let i = 0; i < json.playlists.length; i++) {
      out.push(toPlaylist(json.playlists[i]));
    }
    return out;
  } catch (e) {
    const err = e as Error;
    if (err.message.indexOf('405') >= 0 || err.message.indexOf('403') >= 0) {
      // 被限流就别再试了，歇十几秒再说
      playlistListBlockedUntil = Date.now() + 20000;
      Logger.w('歌单广场被限流，暂停 20 秒');
    }
    throw new Error(err.message);
  }
}

/** 全部歌单榜（保留旧入口） */
export async function fetchTopPlaylists(limit: number = 24, offset: number = 0): Promise<NeteasePlaylist[]> {
  return fetchPlaylistList('全部', limit, offset);
}

/* ───────────────────── 首页推荐：分段数据源 ───────────────────── */

/** 官方「私人雷达」固定歌单 ID */
const PRIVATE_RADAR_ID: number = 3136952023;
/** 飙升榜 / 热歌榜 / 新歌榜 */
export const TOPLIST_SOARING: number = 19723756;
export const TOPLIST_HOT: number = 3778678;
export const TOPLIST_NEW: number = 3779629;

/** 私人雷达：官方固定歌单，取前几首当第一屏推荐 */
export async function fetchRadarSongs(limit: number): Promise<Song[]> {
  const songs = await fetchPlaylistDetail(PRIVATE_RADAR_ID);
  return songs.slice(0, limit);
}

/**
 * 每日推荐。必须登录，未登录服务端返回 301，
 * 这里当空处理，界面按「登录后可见」收起。
 */
export async function fetchDailyRecommendSongs(): Promise<Song[]> {
  const payload: Record<string, Object> = {
    'afresh': 'false'
  };
  const text = (await weapiRequest('/weapi/v3/discovery/recommend/songs', payload)).text;
  const json = JSON.parse(text) as NsDailyRespJson;
  const data = json.data;
  if (json.code !== 200 || data === undefined || data === null) {
    Logger.i(`每日推荐不可用 code=${json.code}`);
    return [];
  }
  const list = data.dailySongs;
  if (list === undefined || list === null) {
    return [];
  }
  const out: Song[] = [];
  for (let i = 0; i < list.length; i++) {
    const s = toSong(list[i]);
    if (s !== null) {
      out.push(s);
    }
  }
  return out;
}

/** 私人 FM / 漫游，同样需要登录 */
export async function fetchPersonalFmSongs(): Promise<Song[]> {
  const payload: Record<string, Object> = {};
  const text = (await weapiRequest('/weapi/v1/radio/get', payload)).text;
  const json = JSON.parse(text) as NsRadioRespJson;
  if (json.code !== 200 || json.data === undefined || json.data === null) {
    Logger.i(`私人FM不可用 code=${json.code}`);
    return [];
  }
  const out: Song[] = [];
  for (let i = 0; i < json.data.length; i++) {
    const s = toSong(json.data[i]);
    if (s !== null) {
      out.push(s);
    }
  }
  return out;
}

/** 新歌条目的外层字段单独拷一份，ArkTS 不允许把结构相近的对象直接当另一个接口用 */
function itemAsSongJson(item: NsNewSongItemJson): NsSongJson {
  const out: NsSongJson = {
    id: item.id,
    name: item.name,
    duration: item.duration,
    album: item.album,
    al: item.album,
    artists: item.artists,
    ar: item.artists
  };
  return out;
}

/** 推荐新歌（匿名可用） */
export async function fetchNewSongs(limit: number = 6): Promise<Song[]> {
  const payload: Record<string, Object> = {
    'type': 'recommend',
    'limit': `${limit}`,
    'areaId': '0'
  };
  const text = (await weapiRequest('/weapi/personalized/newsong', payload)).text;
  const json = JSON.parse(text) as NsNewSongRespJson;
  if (json.code !== 200 || json.result === undefined || json.result === null) {
    return [];
  }
  const out: Song[] = [];
  for (let i = 0; i < json.result.length; i++) {
    const item = json.result[i];
    const inner: NsSongJson = item.song !== undefined && item.song !== null
      ? item.song : itemAsSongJson(item);
    const song = toSong(inner);
    if (song === null) {
      continue;
    }
    // 外层常带一张 picUrl，比 song.album.picUrl 更稳
    if (song.coverUrl.length === 0 && item.picUrl !== undefined && item.picUrl !== null) {
      song.coverUrl = toHttps(item.picUrl);
    }
    out.push(song);
  }
  return out;
}

/** 单曲详情，用于补齐时长/封面（搜索结果偶尔缺字段） */
export async function fetchSongDetail(songId: number): Promise<Song | null> {
  const c = encodeURIComponent(`[{"id":${songId}}]`);
  const ids = encodeURIComponent(`[${songId}]`);
  const text = await getText(`/api/v3/song/detail?c=${c}&ids=${ids}`);
  const json = JSON.parse(text) as NsDetailRespJson;
  if (json.code !== 200 || json.songs === undefined || json.songs === null || json.songs.length === 0) {
    return null;
  }
  return toSong(json.songs[0]);
}

/**
 * 补封面。
 * 明文搜索接口只给 album.picId（加密过的图床 ID），不给 picUrl，
 * 所以搜完拿这一批 ID 再请求一次详情，把封面、专辑名、时长补全。
 * 一次请求能带几十首，开销可以接受。
 */
export async function enrichSongs(songs: Song[]): Promise<Song[]> {
  if (songs.length === 0) {
    return songs;
  }
  const idParts: string[] = [];
  const cParts: string[] = [];
  for (let i = 0; i < songs.length; i++) {
    const id = songs[i].remoteId;
    if (id > 0) {
      idParts.push(`${id}`);
      cParts.push(`{"id":${id}}`);
    }
  }
  if (idParts.length === 0) {
    return songs;
  }
  const c = encodeURIComponent(`[${cParts.join(',')}]`);
  const idsParam = encodeURIComponent(`[${idParts.join(',')}]`);
  try {
    const text = await getText(`/api/v3/song/detail?c=${c}&ids=${idsParam}`);
    const json = JSON.parse(text) as NsDetailRespJson;
    if (json.songs === undefined || json.songs === null || json.songs.length === 0) {
      return songs;
    }
    const byId: Map<number, NsSongJson> = new Map();
    for (let i = 0; i < json.songs.length; i++) {
      const raw = json.songs[i];
      if (raw.id !== undefined) {
        byId.set(raw.id, raw);
      }
    }
    for (let i = 0; i < songs.length; i++) {
      const song = songs[i];
      const hit = byId.get(song.remoteId);
      if (hit === undefined) {
        continue;
      }
      const album = albumOf(hit);
      if (album !== null) {
        const pic = cleanStr(album.picUrl);
        if (pic.length > 0) {
          song.coverUrl = toHttps(pic);
        }
        const albumName = cleanStr(album.name);
        if (albumName.length > 0) {
          song.album = albumName;
        }
      }
      if (song.artist.length === 0) {
        song.artist = artistsOf(hit);
      }
      if (song.durationMs === 0 && hit.dt !== undefined) {
        song.durationMs = hit.dt;
      }
    }
  } catch (e) {
    // 补封面失败不影响搜索结果本身，静默降级成无封面
    Logger.w(`补封面失败 ${(e as Error).message}`);
  }
  return songs;
}

/** 网络是否可用（快速探活，避免每个请求都等到超时） */
export async function ping(): Promise<boolean> {
  try {
    await getText('/api/personalized/playlist?limit=1');
    return true;
  } catch (e) {
    const err = e as BusinessError;
    Logger.w(`网易云探活失败 ${err.message}`);
    return false;
  }
}


/* ───────────────────────── 艺术家 / 评论 / MV ───────────────────────── */

/** 艺人资料 */
export class NeteaseArtistInfo {
  id: number = 0;
  name: string = '';
  /** 别名，多个用 / 连接 */
  alias: string = '';
  briefDesc: string = '';
  avatarUrl: string = '';
  coverUrl: string = '';
  albumSize: number = 0;
  musicSize: number = 0;
  mvSize: number = 0;
}

/** 一条评论 */
export class NeteaseComment {
  id: string = '';
  nickname: string = '';
  avatarUrl: string = '';
  content: string = '';
  likedCount: number = 0;
  timeMs: number = 0;
  /** 被回复人的昵称，没有回复则为空 */
  repliedUser: string = '';
  repliedContent: string = '';
  isHot: boolean = false;
}

/** 一页评论 */
export class NeteaseCommentPage {
  comments: NeteaseComment[] = [];
  total: number = 0;
  hasMore: boolean = false;
  /** 下一页要回传的 cursor */
  cursor: string = '';
}

/** MV 条目 */
export class NeteaseMv {
  id: number = 0;
  name: string = '';
  coverUrl: string = '';
  artistName: string = '';
  durationMs: number = 0;
  playCount: number = 0;
}

/** 解析出来的 MV 播放地址 */
export class NeteaseMvStream {
  url: string = '';
  quality: string = '';
  durationMs: number = 0;
  coverUrl: string = '';
  artistName: string = '';
}

interface NsArtistDetailJson {
  id?: number;
  name?: string | null;
  alias?: string[] | null;
  briefDesc?: string | null;
  avatar?: string | null;
  cover?: string | null;
  img1v1Url?: string | null;
  albumSize?: number;
  musicSize?: number;
  mvSize?: number;
}

interface NsArtistRespJson {
  code?: number;
  artist?: NsArtistDetailJson | null;
}

interface NsArtistSongsRespJson {
  code?: number;
  songs?: NsSongJson[] | null;
}

interface NsArtistAlbumJson {
  id?: number;
  name?: string | null;
  picUrl?: string | null;
  size?: number;
  publishTime?: number;
  artist?: NsArtistJson | null;
  artists?: NsArtistJson[] | null;
}

interface NsArtistAlbumsRespJson {
  code?: number;
  hotAlbums?: NsArtistAlbumJson[] | null;
  more?: boolean;
}

interface NsCommentUserJson {
  userId?: number;
  nickname?: string | null;
  avatarUrl?: string | null;
}

interface NsBeRepliedJson {
  user?: NsCommentUserJson | null;
  content?: string | null;
}

interface NsCommentJson {
  commentId?: number;
  user?: NsCommentUserJson | null;
  content?: string | null;
  likedCount?: number;
  time?: number;
  beReplied?: NsBeRepliedJson[] | null;
  isHot?: boolean;
}

interface NsCommentDataJson {
  comments?: NsCommentJson[] | null;
  hotComments?: NsCommentJson[] | null;
  totalCount?: number;
  total?: number;
  hasMore?: boolean;
  cursor?: string | null;
}

interface NsCommentRespJson {
  code?: number;
  data?: NsCommentDataJson | null;
}

interface NsMvItemJson {
  id?: number;
  name?: string | null;
  imgurl?: string | null;
  cover?: string | null;
  duration?: number;
  playCount?: number;
  artist?: NsArtistJson | null;
  artistName?: string | null;
  /** mv/detail 把各清晰度直链放在这里 */
  brs?: Record<string, string> | null;
}

interface NsArtistMvsRespJson {
  code?: number;
  mvs?: NsMvItemJson[] | null;
  hasMore?: boolean;
}

interface NsMvDetailJson {
  code?: number;
  data?: NsMvItemJson | null;
  brs?: Record<string, string> | null;
}

/** 艺人资料（含简介、单曲数/专辑数/MV 数） */
export async function fetchArtistInfo(artistId: number): Promise<NeteaseArtistInfo | null> {
  const text = await getText(`/api/v1/artist/${artistId}`);
  const json = JSON.parse(text) as NsArtistRespJson;
  if (json.code !== 200 || json.artist === undefined || json.artist === null) {
    return null;
  }
  const a = json.artist;
  const out = new NeteaseArtistInfo();
  out.id = a.id !== undefined ? a.id : artistId;
  out.name = cleanStr(a.name);
  if (a.alias !== undefined && a.alias !== null) {
    out.alias = a.alias.join(' / ');
  }
  out.briefDesc = cleanStr(a.briefDesc);
  out.avatarUrl = toHttps(cleanStr(a.avatar).length > 0 ? cleanStr(a.avatar)
    : cleanStr(a.img1v1Url));
  out.coverUrl = toHttps(cleanStr(a.cover));
  out.albumSize = a.albumSize !== undefined ? a.albumSize : 0;
  out.musicSize = a.musicSize !== undefined ? a.musicSize : 0;
  out.mvSize = a.mvSize !== undefined ? a.mvSize : 0;
  return out;
}

/** 艺人热门单曲 */
export async function fetchArtistSongs(artistId: number, offset: number,
  limit: number): Promise<Song[]> {
  const body = `id=${artistId}&private_cloud=true&work_type=1&order=hot&offset=${offset}&limit=${limit}`;
  const result = await requestRaw('/api/v1/artist/songs', http.RequestMethod.POST, body);
  const json = JSON.parse(result.text) as NsArtistSongsRespJson;
  const list = json.songs;
  if (json.code !== 200 || list === undefined || list === null) {
    return [];
  }
  const out: Song[] = [];
  for (let i = 0; i < list.length; i++) {
    const song = toSong(list[i]);
    if (song !== null) {
      out.push(song);
    }
  }
  return out;
}

/** 艺人专辑 */
export async function fetchArtistAlbums(artistId: number, offset: number,
  limit: number): Promise<NeteasePlaylist[]> {
  const text = await getText(`/api/artist/albums/${artistId}?limit=${limit}&offset=${offset}&total=true`);
  const json = JSON.parse(text) as NsArtistAlbumsRespJson;
  const list = json.hotAlbums;
  if (json.code !== 200 || list === undefined || list === null) {
    return [];
  }
  const out: NeteasePlaylist[] = [];
  for (let i = 0; i < list.length; i++) {
    const a = list[i];
    const p = new NeteasePlaylist();
    p.id = a.id !== undefined ? a.id : 0;
    p.name = cleanStr(a.name);
    p.coverUrl = toHttps(cleanStr(a.picUrl));
    p.trackCount = a.size !== undefined ? a.size : 0;
    const artist = a.artist !== undefined && a.artist !== null ? a.artist
      : (a.artists !== undefined && a.artists !== null && a.artists.length > 0 ? a.artists[0] : null);
    p.creator = artist === null ? '' : cleanStr(artist.name);
    if (a.publishTime !== undefined && a.publishTime > 0) {
      p.year = `${new Date(a.publishTime).getFullYear()}`;
    }
    out.push(p);
  }
  return out;
}

/** 艺人 MV 列表 */
export async function fetchArtistMvs(artistId: number, offset: number,
  limit: number): Promise<NeteaseMv[]> {
  const text = await getText(`/api/artist/mvs?artistId=${artistId}&limit=${limit}&offset=${offset}&total=true`);
  const json = JSON.parse(text) as NsArtistMvsRespJson;
  const list = json.mvs;
  if (json.code !== 200 || list === undefined || list === null) {
    return [];
  }
  const out: NeteaseMv[] = [];
  for (let i = 0; i < list.length; i++) {
    const m = list[i];
    const mv = new NeteaseMv();
    mv.id = m.id !== undefined ? m.id : 0;
    mv.name = cleanStr(m.name);
    mv.coverUrl = toHttps(cleanStr(m.imgurl).length > 0 ? cleanStr(m.imgurl) : cleanStr(m.cover));
    const artistName = cleanStr(m.artistName);
    mv.artistName = artistName.length > 0 ? artistName
      : (m.artist !== undefined && m.artist !== null ? cleanStr(m.artist.name) : '');
    mv.durationMs = m.duration !== undefined ? m.duration : 0;
    mv.playCount = m.playCount !== undefined ? m.playCount : 0;
    if (mv.id > 0) {
      out.push(mv);
    }
  }
  return out;
}

function toComment(json: NsCommentJson, hot: boolean): NeteaseComment {
  const c = new NeteaseComment();
  c.id = json.commentId !== undefined ? `${json.commentId}` : '';
  const user = json.user;
  c.nickname = user === undefined || user === null ? '' : cleanStr(user.nickname);
  c.avatarUrl = user === undefined || user === null ? '' : toHttps(cleanStr(user.avatarUrl));
  c.content = cleanStr(json.content);
  c.likedCount = json.likedCount !== undefined ? json.likedCount : 0;
  c.timeMs = json.time !== undefined ? json.time : 0;
  c.isHot = hot;
  const replied = json.beReplied;
  if (replied !== undefined && replied !== null && replied.length > 0) {
    c.repliedUser = replied[0].user === undefined || replied[0].user === null
      ? '' : cleanStr(replied[0].user!.nickname);
    c.repliedContent = cleanStr(replied[0].content);
  }
  return c;
}

/**
 * 歌曲评论。
 * sortType: 2 推荐（热门+按热度），3 按时间，99 按热度
 * cursor 由上一页返回；首页推荐传 normalHot#offset，最新传 0。
 */
export async function fetchComments(songId: number, pageNo: number, pageSize: number,
  sortType: number, cursor: string): Promise<NeteaseCommentPage> {
  const threadId = encodeURIComponent(`R_SO_4_${songId}`);
  const path = `/api/v2/resource/comments?threadId=${threadId}&pageNo=${pageNo}`
    + `&pageSize=${pageSize}&sortType=${sortType}&cursor=${encodeURIComponent(cursor)}&showInner=true`;
  const text = await getText(path);
  const json = JSON.parse(text) as NsCommentRespJson;
  const out = new NeteaseCommentPage();
  const data = json.data;
  if (json.code !== 200 || data === undefined || data === null) {
    return out;
  }
  const seen: Set<string> = new Set<string>();
  const list = data.comments;
  if (list !== undefined && list !== null) {
    for (let i = 0; i < list.length; i++) {
      const c = toComment(list[i], false);
      seen.add(c.id);
      out.comments.push(c);
    }
  }
  // 有的节点会把热门评论也塞进 comments，这里按 id 去重
  const hot = data.hotComments;
  if (hot !== undefined && hot !== null) {
    for (let i = 0; i < hot.length; i++) {
      const c = toComment(hot[i], true);
      if (!seen.has(c.id)) {
        seen.add(c.id);
        out.comments.push(c);
      }
    }
  }
  const total = data.totalCount !== undefined ? data.totalCount
    : (data.total !== undefined ? data.total : 0);
  out.total = total;
  out.hasMore = data.hasMore === true;
  out.cursor = cleanStr(data.cursor);
  return out;
}

/** MV 播放地址：老的 /api/mv/url 已下线，直链在 detail 的 brs 里 */
export async function fetchMvStream(mvId: number): Promise<NeteaseMvStream> {
  const text = await getText(`/api/mv/detail?id=${mvId}`);
  const json = JSON.parse(text) as NsMvDetailJson;
  const out = new NeteaseMvStream();
  if (json.code !== 200 || json.data === undefined || json.data === null) {
    return out;
  }
  const data = json.data;
  out.durationMs = data.duration !== undefined ? data.duration : 0;
  out.coverUrl = toHttps(cleanStr(data.cover).length > 0 ? cleanStr(data.cover) : cleanStr(data.imgurl));
  out.artistName = cleanStr(data.artistName);
  const brs = json.brs !== undefined && json.brs !== null ? json.brs : data.brs;
  if (brs === undefined || brs === null) {
    return out;
  }
  const keys = Object.keys(brs);
  let best = 0;
  let lowest = 0;
  for (let i = 0; i < keys.length; i++) {
    const n = Number(keys[i]);
    if (Number.isNaN(n) || cleanStr(brs[keys[i]]).length === 0) {
      continue;
    }
    if (lowest === 0 || n < lowest) {
      lowest = n;
    }
    if (n <= 1080 && n > best) {
      best = n;
    }
  }
  // 优先 1080P 及以下：4K 档在部分机型上会退回软解，功耗高还容易掉帧。
  // 只有 4K 档时退而取最低档，保证走硬件解码。
  if (best === 0) {
    best = lowest;
  }
  if (best > 0) {
    out.url = toHttps(cleanStr(brs[`${best}`]));
    out.quality = `${best}P`;
  }
  return out;
}

/** 歌单概要（雷达歌单用，只要封面/名字/曲目数，不拉整份曲目） */
export async function fetchPlaylistSummary(id: number): Promise<NeteasePlaylist | null> {
  try {
    const text = await getText(`/api/v6/playlist/detail?id=${id}&n=1&s=0`);
    const json = JSON.parse(text) as NsPlaylistRespJson;
    const p = json.playlist;
    if (json.code !== 200 || p === undefined || p === null) {
      return null;
    }
    return toPlaylist(p);
  } catch (e) {
    Logger.w(`读取歌单概要失败 ${id}: ${(e as Error).message}`);
    return null;
  }
}
