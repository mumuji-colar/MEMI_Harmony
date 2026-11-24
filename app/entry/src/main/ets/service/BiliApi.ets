import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';
import { md5Hex } from './NeteaseCrypto';

/**
 * B 站 Web 端匿名接口。
 *
 * 只做自动换源需要的最小集合：搜索 → 视频信息（拿 cid）→ 取音轨。
 * 不登录也能用，但拿不到大会员音轨（普通音轨最高约 192k）。
 */

const UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const REFERER: string = 'https://www.bilibili.com/';

const NAV_URL: string = 'https://api.bilibili.com/x/web-interface/nav';
const SEARCH_URL: string = 'https://api.bilibili.com/x/web-interface/wbi/search/type';
const VIEW_URL: string = 'https://api.bilibili.com/x/web-interface/wbi/view';
const PLAY_URL: string = 'https://api.bilibili.com/x/player/wbi/playurl';

/** Wbi 混淆索引表，与网页端一致 */
const MIXIN_INDEX: number[] = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
  27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
  37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
  22, 25, 54, 21, 56, 62, 6, 63, 57, 20, 34, 52, 59, 11, 36, 44
];

const WBI_CACHE_MS: number = 10 * 60 * 1000;

let mixinKey: string = '';
let mixinAt: number = 0;

/* ───────────────────────── 数据结构 ───────────────────────── */

export class BiliSearchItem {
  aid: number = 0;
  bvid: string = '';
  title: string = '';
  author: string = '';
  durationSec: number = 0;
  play: number = 0;
}

export class BiliPage {
  cid: number = 0;
  page: number = 0;
  part: string = '';
  durationSec: number = 0;
}

export class BiliVideoInfo {
  bvid: string = '';
  title: string = '';
  ownerName: string = '';
  pages: BiliPage[] = [];
}

export class BiliAudioStream {
  url: string = '';
  backupUrls: string[] = [];
  bandwidth: number = 0;
  mimeType: string = '';
}

interface NavDataJson {
  wbi_img?: WbiImg | null;
}

interface WbiImg {
  img_url?: string;
  sub_url?: string;
}

interface NavRespJson {
  code?: number;
  data?: NavDataJson | null;
}

interface SearchItemJson {
  type?: string;
  aid?: number;
  bvid?: string;
  title?: string;
  author?: string;
  duration?: string;
  play?: number;
}

interface SearchDataJson {
  result?: SearchItemJson[] | null;
}

interface SearchRespJson {
  code?: number;
  data?: SearchDataJson | null;
}

interface OwnerJson {
  name?: string;
}

interface PageJson {
  cid?: number;
  page?: number;
  part?: string;
  duration?: number;
}

interface ViewDataJson {
  bvid?: string;
  title?: string;
  owner?: OwnerJson | null;
  pages?: PageJson[] | null;
}

interface ViewRespJson {
  code?: number;
  data?: ViewDataJson | null;
}

interface DashItemJson {
  id?: number;
  baseUrl?: string;
  base_url?: string;
  backupUrl?: string[] | null;
  backup_url?: string[] | null;
  bandwidth?: number;
  mimeType?: string;
  mime_type?: string;
}

interface DashJson {
  audio?: DashItemJson[] | null;
}

interface PlayDataJson {
  dash?: DashJson | null;
}

interface PlayRespJson {
  code?: number;
  message?: string;
  data?: PlayDataJson | null;
}

/* ───────────────────────── HTTP ───────────────────────── */

async function getText(url: string, params: Record<string, string> | null): Promise<string> {
  let full = url;
  if (params !== null) {
    const keys = Object.keys(params);
    const parts: string[] = [];
    for (let i = 0; i < keys.length; i++) {
      parts.push(`${encodeURIComponent(keys[i])}=${encodeURIComponent(params[keys[i]])}`);
    }
    full += (url.indexOf('?') >= 0 ? '&' : '?') + parts.join('&');
  }
  const req = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': UA,
        'Referer': REFERER,
        'Accept': 'application/json'
      },
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 8000,
      readTimeout: 10000,
      usingCache: false
    };
    const resp = await req.request(full, options);
    if (resp.responseCode !== 200) {
      throw new Error(`HTTP ${resp.responseCode}`);
    }
    return resp.result as string;
  } finally {
    req.destroy();
  }
}

/* ───────────────────────── Wbi 签名 ───────────────────────── */

function nameOfUrl(url: string): string {
  const slash = url.lastIndexOf('/');
  const name = slash >= 0 ? url.substring(slash + 1) : url;
  const dot = name.indexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

async function fetchMixinKey(): Promise<string> {
  const text = await getText(NAV_URL, null);
  const json = JSON.parse(text) as NavRespJson;
  const data = json.data;
  const img = data !== undefined && data !== null ? data.wbi_img : null;
  if (img === undefined || img === null) {
    throw new Error('nav 没有 wbi_img');
  }
  const imgUrl = img.img_url === undefined ? '' : img.img_url;
  const subUrl = img.sub_url === undefined ? '' : img.sub_url;
  if (imgUrl.length === 0 || subUrl.length === 0) {
    throw new Error('wbi 链接为空');
  }
  const raw = nameOfUrl(imgUrl) + nameOfUrl(subUrl);
  let mixed = '';
  for (let i = 0; i < MIXIN_INDEX.length; i++) {
    const idx = MIXIN_INDEX[i];
    if (idx < raw.length) {
      mixed += raw.charAt(idx);
    }
  }
  return mixed.length >= 32 ? mixed.substring(0, 32) : mixed;
}

async function getMixinKey(): Promise<string> {
  const now = Date.now();
  if (mixinKey.length > 0 && now - mixinAt < WBI_CACHE_MS) {
    return mixinKey;
  }
  mixinKey = await fetchMixinKey();
  mixinAt = now;
  Logger.i('B站 Wbi key 已刷新');
  return mixinKey;
}

/** 值里的特殊字符要先剔除，否则签名和实际请求对不上 */
function filterValue(value: string): string {
  return value.replace(/[!'()*]/g, '');
}

async function signed(params: Record<string, string>): Promise<Record<string, string>> {
  const key = await getMixinKey();
  const out: Record<string, string> = {};
  const keys = Object.keys(params);
  for (let i = 0; i < keys.length; i++) {
    out[keys[i]] = filterValue(params[keys[i]]);
  }
  out['wts'] = `${Math.floor(Date.now() / 1000)}`;
  const sorted = Object.keys(out).sort();
  const parts: string[] = [];
  for (let i = 0; i < sorted.length; i++) {
    parts.push(`${encodeURIComponent(sorted[i])}=${encodeURIComponent(out[sorted[i]])}`);
  }
  out['w_rid'] = await md5Hex(parts.join('&') + key);
  return out;
}

/* ───────────────────────── 解析工具 ───────────────────────── */

function stripHtml(html: string): string {
  return html.replace(/<[^>]+>/g, '');
}

/** "4:30" / "1:02:03" → 秒 */
function durationToSec(value: string): number {
  if (value.length === 0) {
    return 0;
  }
  const parts = value.split(':');
  let total = 0;
  for (let i = 0; i < parts.length; i++) {
    const n = Number(parts[i]);
    if (!Number.isNaN(n)) {
      total = total * 60 + n;
    }
  }
  return total;
}

function httpsUrl(url: string): string {
  if (url.startsWith('//')) {
    return `https:${url}`;
  }
  if (url.startsWith('http://')) {
    return `https://${url.substring(7)}`;
  }
  return url;
}

/* ───────────────────────── 对外接口 ───────────────────────── */

/** 搜索视频，duration: 0 全部 / 1 <10min / 2 10-30 / 3 30-60 / 4 >60 */
export async function biliSearch(keyword: string, duration: number): Promise<BiliSearchItem[]> {
  const params = await signed({
    'search_type': 'video',
    'keyword': keyword,
    'order': 'totalrank',
    'duration': `${duration}`,
    'tids': '0',
    'page': '1'
  });
  const text = await getText(SEARCH_URL, params);
  const json = JSON.parse(text) as SearchRespJson;
  const data = json.data;
  const list = data !== undefined && data !== null ? data.result : null;
  const out: BiliSearchItem[] = [];
  if (list === undefined || list === null) {
    return out;
  }
  for (let i = 0; i < list.length; i++) {
    const it = list[i];
    if (it.type !== 'video') {
      continue;
    }
    const item = new BiliSearchItem();
    item.aid = it.aid === undefined ? 0 : it.aid;
    item.bvid = it.bvid === undefined ? '' : it.bvid;
    item.title = stripHtml(it.title === undefined ? '' : it.title);
    item.author = it.author === undefined ? '' : it.author;
    item.durationSec = durationToSec(it.duration === undefined ? '' : it.duration);
    item.play = it.play === undefined ? 0 : it.play;
    if (item.bvid.length > 0) {
      out.push(item);
    }
  }
  return out;
}

/** 视频信息（含分 P 的 cid） */
export async function biliView(bvid: string): Promise<BiliVideoInfo | null> {
  try {
    const params = await signed({ 'bvid': bvid });
    const text = await getText(VIEW_URL, params);
    const json = JSON.parse(text) as ViewRespJson;
    const data = json.data;
    if (data === undefined || data === null) {
      return null;
    }
    const info = new BiliVideoInfo();
    info.bvid = data.bvid === undefined ? bvid : data.bvid;
    info.title = data.title === undefined ? '' : data.title;
    const owner = data.owner;
    info.ownerName = owner !== undefined && owner !== null && owner.name !== undefined ? owner.name : '';
    const pages = data.pages;
    if (pages !== undefined && pages !== null) {
      for (let i = 0; i < pages.length; i++) {
        const p = pages[i];
        const page = new BiliPage();
        page.cid = p.cid === undefined ? 0 : p.cid;
        page.page = p.page === undefined ? 0 : p.page;
        page.part = p.part === undefined ? '' : p.part;
        page.durationSec = p.duration === undefined ? 0 : p.duration;
        if (page.cid > 0) {
          info.pages.push(page);
        }
      }
    }
    return info;
  } catch (e) {
    const err = e as BusinessError;
    Logger.w(`B站视频信息失败 ${bvid} ${err.message}`);
    return null;
  }
}

/** 取 DASH 音轨，返回码率最高的一条；没有就返回 null */
export async function biliAudio(bvid: string, cid: number): Promise<BiliAudioStream | null> {
  try {
    const params = await signed({
      'bvid': bvid,
      'cid': `${cid}`,
      'fnval': '4048',
      'fnver': '0',
      'fourk': '0',
      'otype': 'json',
      'platform': 'pc'
    });
    const text = await getText(PLAY_URL, params);
    const json = JSON.parse(text) as PlayRespJson;
    if (json.code !== 0) {
      Logger.w(`B站取流失败 code=${json.code} ${json.message}`);
      return null;
    }
    const data = json.data;
    const dash = data !== undefined && data !== null ? data.dash : null;
    const audios = dash !== undefined && dash !== null ? dash.audio : null;
    if (audios === undefined || audios === null || audios.length === 0) {
      return null;
    }
    let best: DashItemJson | null = null;
    for (let i = 0; i < audios.length; i++) {
      const a = audios[i];
      const bw = a.bandwidth === undefined ? 0 : a.bandwidth;
      if (best === null || bw > (best.bandwidth === undefined ? 0 : best.bandwidth)) {
        best = a;
      }
    }
    if (best === null) {
      return null;
    }
    const url = httpsUrl(best.baseUrl !== undefined ? best.baseUrl
      : (best.base_url !== undefined ? best.base_url : ''));
    if (url.length === 0) {
      return null;
    }
    const stream = new BiliAudioStream();
    stream.url = url;
    stream.bandwidth = best.bandwidth === undefined ? 0 : best.bandwidth;
    stream.mimeType = best.mimeType !== undefined ? best.mimeType
      : (best.mime_type !== undefined ? best.mime_type : 'audio/mp4');
    const backups = best.backupUrl !== undefined && best.backupUrl !== null ? best.backupUrl
      : (best.backup_url !== undefined && best.backup_url !== null ? best.backup_url : []);
    for (let i = 0; i < backups.length; i++) {
      const u = httpsUrl(backups[i]);
      if (u.length > 0) {
        stream.backupUrls.push(u);
      }
    }
    return stream;
  } catch (e) {
    const err = e as BusinessError;
    Logger.w(`B站取流异常 ${bvid}/${cid} ${err.message}`);
    return null;
  }
}
