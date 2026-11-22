/**
 * 网易云会话凭据。
 *
 * 单独放一个模块是为了打断循环依赖：
 * NeteaseApi 需要读 Cookie，NeteaseAuth 需要调 NeteaseApi 发登录请求，
 * 两边都只依赖这个没有 import 的小容器。
 */

let cookie: string = '';

/** 当前请求要带的 Cookie 头，空串表示匿名 */
export function getCookie(): string {
  return cookie;
}

export function setCookie(value: string): void {
  cookie = value.trim();
}

export function clearCookie(): void {
  cookie = '';
}

export function hasCookie(): boolean {
  return cookie.length > 0;
}

/** 会被写进请求头的凭据键，顺序无意义 */
const KEEP_KEYS: string[] = ['MUSIC_U', '__csrf', 'MUSIC_A', '__remember_me', 'NMTID'];

/** 这些是 Set-Cookie 的属性，不是真正的 cookie */
const ATTR_KEYS: string[] = ['expires', 'path', 'domain', 'max-age', 'samesite', 'secure', 'httponly', 'version'];

/**
 * 把服务端给的 cookie 文本解析成键值对。
 *
 * 两种格式都要认：
 * 1. 请求头那种：`MUSIC_U=xxx; __csrf=yyy`
 * 2. **NetScape 制表符格式**（`HttpResponse.cookies` 给的就是这个）：
 *    `domain \t flag \t path \t secure \t expiry \t name \t value`
 *
 * 只认第一种会漏掉 MUSIC_U —— 这正是「扫码确认了、验证码也对了，但一直未登录」的原因。
 */
export function parseCookiePairs(raw: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (raw.length === 0) {
    return out;
  }

  // 格式 2：一行一条，按制表符切
  const lines = raw.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.indexOf('\t') < 0) {
      continue;
    }
    const fields = line.split('\t');
    if (fields.length >= 7) {
      const name = fields[5].trim();
      const value = fields[6].trim();
      if (name.length > 0 && value.length > 0) {
        out[name] = value;
      }
    }
  }

  // 格式 1：name=value，可能用 ; 或 , 分隔
  const segments = raw.split(';');
  for (let i = 0; i < segments.length; i++) {
    const piece = segments[i];
    // NetScape 行里带制表符，跳过，已经在上面处理
    if (piece.indexOf('\t') >= 0) {
      continue;
    }
    const eq = piece.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    const name = piece.substring(0, eq).trim();
    let value = piece.substring(eq + 1).trim();
    // 去掉值后面的换行与引号
    const cut = value.search(/[\r\n,]/);
    if (cut >= 0) {
      value = value.substring(0, cut).trim();
    }
    value = value.replace(/^"/, '').replace(/"$/, '');
    const lower = name.toLowerCase();
    if (ATTR_KEYS.indexOf(lower) >= 0) {
      continue;
    }
    if (name.length > 0 && value.length > 0 && out[name] === undefined) {
      out[name] = value;
    }
  }

  return out;
}

/** 从任意文本里提取我们需要的凭据，拼成请求头格式 */
export function extractCredential(raw: string): string {
  const pairs = parseCookiePairs(raw);
  const parts: string[] = [];
  for (let i = 0; i < KEEP_KEYS.length; i++) {
    const key = KEEP_KEYS[i];
    const value = pairs[key];
    if (value !== undefined && value.length > 0) {
      parts.push(`${key}=${value}`);
    }
  }
  return parts.join('; ');
}

/** 是否拿到了真正的登录凭据 */
export function hasLoginCredential(raw: string): boolean {
  return parseCookiePairs(raw)['MUSIC_U'] !== undefined;
}
