import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';

/**
 * 网易云 eapi 加密。
 *
 * 比 Android 版省事得多：eapi 只用 AES-128-ECB + MD5，**不需要 RSA**。
 * 之前没做是因为明文 api 已经够用；现在要拿无损/高码率，就得走
 * /eapi/song/enhance/player/url/v1，所以才补上这一层。
 *
 * 报文格式（与官方客户端一致）：
 *   message = "{apiPath}-36cd479b6b5-{jsonBody}-36cd479b6b5-{md5(salt)}"
 *   salt    = "nobody{apiPath}use{jsonBody}md5forencrypt"
 *   params  = AES-128-ECB(message, "e82ckenh8dichen8") 的十六进制大写
 */

const EAPI_KEY: string = 'e82ckenh8dichen8';
const EAPI_SEP: string = '-36cd479b6b5-';

function utf8Bytes(text: string): Uint8Array {
  return new util.TextEncoder('utf-8').encodeInto(text);
}

function toHex(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    const v = bytes[i] & 0xFF;
    out += v < 16 ? `0${v.toString(16)}` : v.toString(16);
  }
  return out;
}

/** MD5 十六进制小写 */
export async function md5Hex(text: string): Promise<string> {
  const md = cryptoFramework.createMd('MD5');
  await md.update({ data: utf8Bytes(text) });
  const digest = await md.digest();
  return toHex(digest.data).toLowerCase();
}

/** AES-128-ECB / PKCS7 加密，返回十六进制小写 */
export async function aesEcbHex(text: string, key: string): Promise<string> {
  const generator = cryptoFramework.createSymKeyGenerator('AES128');
  const symKey = await generator.convertKey({ data: utf8Bytes(key) });
  const cipher = cryptoFramework.createCipher('AES128|ECB|PKCS7');
  await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, null);
  const output = await cipher.doFinal({ data: utf8Bytes(text) });
  return toHex(output.data).toLowerCase();
}

/**
 * 把一个 JSON 载荷打包成 eapi 的 params 参数。
 * @param path 形如 /eapi/song/enhance/player/url/v1
 */
export async function eapiParams(path: string, payload: Record<string, string>): Promise<string> {
  const apiPath = path.replace('/eapi', '/api');
  const body = JSON.stringify(payload);
  const digest = await md5Hex(`nobody${apiPath}use${body}md5forencrypt`);
  const message = `${apiPath}${EAPI_SEP}${body}${EAPI_SEP}${digest}`;
  const cipherHex = await aesEcbHex(message, EAPI_KEY);
  return cipherHex.toUpperCase();
}

/* ───────────────────── weapi（AES-CBC + 裸 RSA） ───────────────────── */

const PRESET_KEY: string = '0CoJUm6Qyw8W8jud';
const CBC_IV: string = '0102030405060708';
const PUBLIC_KEY_B64: string = 'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFb'
  + 't7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZ'
  + 'MldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB';
const RSA_MODULUS_B64: string = 'gQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45w==';
const RSA_EXPONENT: number = 65537;

function aesCbcBase64(text: string, key: string): Promise<string> {
  return (async (): Promise<string> => {
    const generator = cryptoFramework.createSymKeyGenerator('AES128');
    const symKey = await generator.convertKey({ data: utf8Bytes(key) });
    const cipher = cryptoFramework.createCipher('AES128|CBC|PKCS7');
    const spec: cryptoFramework.IvParamsSpec = {
      algName: 'IvParamsSpec',
      iv: { data: utf8Bytes(CBC_IV) }
    };
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, spec);
    const output = await cipher.doFinal({ data: utf8Bytes(text) });
    return new util.Base64Helper().encodeToStringSync(output.data);
  })();
}

/* ── 裸 RSA（无填充）：先把系统实现试一遍，不行再用手写大数 ── */

function hexToBytes(hex: string): Uint8Array {
  const h = hex.length % 2 === 0 ? hex : `0${hex}`;
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(h.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function bytesToHex(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    const v = bytes[i] & 0xFF;
    out += v < 16 ? `0${v.toString(16)}` : v.toString(16);
  }
  return out;
}

/** 用系统能力做 RSA/ECB/NoPadding */
async function rsaRawViaFramework(block: Uint8Array): Promise<string> {
  const der = new util.Base64Helper().decodeSync(PUBLIC_KEY_B64);
  const generator = cryptoFramework.createAsyKeyGenerator('RSA1024');
  const keyPair = await generator.convertKey({ data: der }, null);
  const cipher = cryptoFramework.createCipher('RSA1024|NoPadding');
  await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, keyPair.pubKey, null);
  const output = await cipher.doFinal({ data: block });
  let hex = bytesToHex(output.data);
  // 有的实现会去掉前导零，补回到 128 字节
  while (hex.length < 256) {
    hex = `0${hex}`;
  }
  return hex;
}

/* 手写大数：16 位一肢，小端 */

function hexToLimbs(hex: string): number[] {
  const h = hex.length % 4 === 0 ? hex : '0'.repeat(4 - hex.length % 4) + hex;
  const limbs: number[] = [];
  for (let i = h.length; i > 0; i -= 4) {
    limbs.push(parseInt(h.substring(i - 4, i), 16));
  }
  return limbs;
}

function cmpLimbs(a: number[], b: number[]): number {
  const n = a.length > b.length ? a.length : b.length;
  for (let i = n - 1; i >= 0; i--) {
    const av = i < a.length ? a[i] : 0;
    const bv = i < b.length ? b[i] : 0;
    if (av !== bv) {
      return av > bv ? 1 : -1;
    }
  }
  return 0;
}

function subLimbs(a: number[], b: number[]): void {
  let borrow = 0;
  for (let i = 0; i < a.length; i++) {
    const bv = (i < b.length ? b[i] : 0) + borrow;
    let diff = a[i] - bv;
    if (diff < 0) {
      diff += 0x10000;
      borrow = 1;
    } else {
      borrow = 0;
    }
    a[i] = diff;
  }
}

function mulLimbs(a: number[], b: number[]): number[] {
  const out: number[] = new Array<number>(a.length + b.length + 1).fill(0);
  for (let i = 0; i < a.length; i++) {
    let carry = 0;
    for (let j = 0; j < b.length; j++) {
      const cur = out[i + j] + a[i] * b[j] + carry;
      out[i + j] = cur & 0xFFFF;
      carry = Math.floor(cur / 0x10000);
    }
    let k = i + b.length;
    while (carry > 0) {
      const cur = out[k] + carry;
      out[k] = cur & 0xFFFF;
      carry = Math.floor(cur / 0x10000);
      k++;
    }
  }
  return out;
}

/** a*b mod m，逐位归约，避免写长除法 */
function mulMod(a: number[], b: number[], m: number[]): number[] {
  const product = mulLimbs(a, b);
  const len = m.length + 1;
  const rem: number[] = new Array<number>(len).fill(0);
  const modPad: number[] = new Array<number>(len).fill(0);
  for (let i = 0; i < m.length; i++) {
    modPad[i] = m[i];
  }
  const totalBits = product.length * 16;
  for (let bit = totalBits - 1; bit >= 0; bit--) {
    // rem <<= 1
    let carry = 0;
    for (let i = 0; i < len; i++) {
      const v = (rem[i] << 1) | carry;
      rem[i] = v & 0xFFFF;
      carry = v >> 16;
    }
    const limbIdx = bit >> 4;
    const bitIdx = bit & 15;
    if (limbIdx < product.length && ((product[limbIdx] >> bitIdx) & 1) === 1) {
      rem[0] |= 1;
    }
    if (cmpLimbs(rem, modPad) >= 0) {
      subLimbs(rem, modPad);
    }
  }
  while (rem.length > 1 && rem[rem.length - 1] === 0) {
    rem.pop();
  }
  return rem;
}

function modPowLimbs(base: number[], exponent: number, mod: number[]): number[] {
  let result: number[] = [1];
  let b = base;
  let e = exponent;
  while (e > 0) {
    if ((e & 1) === 1) {
      result = mulMod(result, b, mod);
    }
    b = mulMod(b, b, mod);
    e = Math.floor(e / 2);
  }
  return result;
}

/** 手写实现的裸 RSA，系统不支持 NoPadding 时兜底 */
function rsaRawManual(block: Uint8Array): string {
  const modulus = hexToLimbs(bytesToHex(new util.Base64Helper().decodeSync(RSA_MODULUS_B64)));
  const base = hexToLimbs(bytesToHex(block));
  const out = modPowLimbs(base, RSA_EXPONENT, modulus);
  let hex = '';
  for (let i = out.length - 1; i >= 0; i--) {
    const v = out[i];
    const part = v.toString(16);
    hex += v < 16 ? `000${part}` : v < 256 ? `00${part}` : v < 4096 ? `0${part}` : part;
  }
  while (hex.length < 256) {
    hex = `0${hex}`;
  }
  return hex.substring(hex.length - 256);
}

/**
 * weapi 的 encSecKey：把 16 位随机密钥倒序后左补零到 128 字节，再做裸 RSA。
 * 先试系统 NoPadding，失败退回手写大数。
 */
async function rsaRawHex(text: string): Promise<string> {
  const raw = utf8Bytes(text);
  const block = new Uint8Array(128);
  block.set(raw, 128 - raw.length);
  try {
    return await rsaRawViaFramework(block);
  } catch (e) {
    Logger.w(`系统 RSA NoPadding 不可用（${(e as BusinessError).code}），改用手写大数`);
    return rsaRawManual(block);
  }
}

/** 生成 weapi 的 params 与 encSecKey */
export async function weapiParams(payload: Record<string, Object>,
  fixedKey: string = ''): Promise<Record<string, string>> {
  const json = JSON.stringify(payload);
  const secretKey = fixedKey.length > 0 ? fixedKey : randomAesKey();
  const first = await aesCbcBase64(json, PRESET_KEY);
  const params = await aesCbcBase64(first, secretKey);
  const reversed = secretKey.split('').reverse().join('');
  const encSecKey = await rsaRawHex(reversed);
  const out: Record<string, string> = {};
  out['params'] = params;
  out['encSecKey'] = encSecKey;
  return out;
}

function randomAesKey(): string {
  const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  let out = '';
  for (let i = 0; i < 16; i++) {
    out += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return out;
}

/** 自检：拿固定输入对一遍已知结果，改加密实现时可以快速发现回归 */
export async function selfTest(): Promise<boolean> {
  try {
    const md5Ok = (await md5Hex('abc')) === '900150983cd24fb0d6963f7d28e17f72';
    const aesOk = (await aesEcbHex('hello world', EAPI_KEY)) === '5aa3f15581585a4011834699fd2472e7';
    const payload: Record<string, Object> = {};
    payload['type'] = 1;
    payload['noCheckToken'] = true;
    const w = await weapiParams(payload, '0123456789abcdef');
    const paramsOk = w['params'] === 'YrMKn0ROo3kP9VVGF7WAg6qsDTyt7uDMLqq2i2FlPCMeqy3z7eYpRbw4QWZirIFQ';
    const keyOk = w['encSecKey'] ===
      '35701388baf89fed412e11269b9c76625d095ecaf17f03fa018abe19ea2d38b949debf242ee39a71ca1f6cda71b1b86a45aa909ee27f7e78e267d34e732f0de948206c3340a788d0003372183e2f753c1f78b66ac23d134ac1fc9b993156520ea826b8aa89a962d4491b4b8d7e08738e1da9b07aa39bf4a7ef0b1c210728cd52';
    return md5Ok && aesOk && paramsOk && keyOk;
  } catch (e) {
    const err = e as BusinessError;
    return false;
  }
}
