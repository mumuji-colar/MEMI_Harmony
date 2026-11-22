import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';

/** 标签区最多读这么多，防止遇到损坏的 size 字段把内存吃光 */
const MAX_TAG_BYTES: number = 4 * 1024 * 1024;
/** 歌词文本本身的上限 */
const MAX_TEXT_BYTES: number = 256 * 1024;

/**
 * 从音频文件里读内嵌歌词。
 *
 * 系统 API 的 AVMetadataExtractor 只给标题/艺术家/专辑/封面，**没有歌词字段**，
 * 所以这里自己扫容器头：
 * - MP3 → ID3v2 的 USLT 帧（v2.3 / v2.4）
 * - FLAC / Ogg → Vorbis Comment 里的 LYRICS / UNSYNCEDLYRICS
 * - M4A / MP4 → moov.udta.meta.ilst 里的 ©lyr
 *
 * 只读文件头附近的标签区，不解析音频帧，成本很低。
 */
export class EmbeddedLyric {
  /** 读不到就返回空串；异常一律吞掉，歌词读不出来不该影响播放 */
  read(path: string): string {
    if (path.length === 0) {
      return '';
    }
    let fd: number = -1;
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      fd = file.fd;
      const size = fs.statSync(fd).size;
      if (size <= 12) {
        return '';
      }
      const head = this.readAt(fd, 0, 12);

      // "ID3"
      if (head.length >= 10 && head[0] === 0x49 && head[1] === 0x44 && head[2] === 0x33) {
        return this.fromId3(fd, size);
      }
      // "fLaC"
      if (head.length >= 4 && head[0] === 0x66 && head[1] === 0x4C && head[2] === 0x61 && head[3] === 0x43) {
        return this.fromFlac(fd, size);
      }
      // MP4: [4 字节 size]['f''t''y''p']
      if (head.length >= 8 && head[4] === 0x66 && head[5] === 0x74 && head[6] === 0x79 && head[7] === 0x70) {
        return this.fromMp4(fd, size);
      }
      return '';
    } catch (e) {
      const err = e as BusinessError;
      Logger.w(`读内嵌歌词失败 ${err.code}`);
      return '';
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (e) {
          Logger.w('关闭内嵌歌词 fd 失败');
        }
      }
    }
  }

  // ---------- ID3v2 ----------

  private fromId3(fd: number, fileSize: number): string {
    const header = this.readAt(fd, 0, 10);
    if (header.length < 10) {
      return '';
    }
    const major = header[3];
    const flags = header[5];
    const tagSize = this.syncsafe(header, 6);
    if (tagSize <= 0) {
      return '';
    }

    let pos = 10;
    // 扩展头：v2.3 是 4 字节普通长度，v2.4 是 syncsafe
    if ((flags & 0x40) !== 0 && major >= 3) {
      const ext = this.readAt(fd, pos, 4);
      if (ext.length < 4) {
        return '';
      }
      const extSize = major === 4 ? this.syncsafe(ext, 0) : this.be32(ext, 0);
      pos += 4 + extSize + (major === 4 ? 0 : 0);
    }

    const tagEnd = Math.min(fileSize, 10 + tagSize);
    const limit = Math.min(tagEnd, 10 + MAX_TAG_BYTES);
    let guard = 0;
    while (pos + 10 <= limit && guard < 512) {
      guard++;
      const fh = this.readAt(fd, pos, 10);
      if (fh.length < 10) {
        break;
      }
      // 到 padding（全 0）就结束
      if (fh[0] === 0) {
        break;
      }
      const id = this.ascii4(fh, 0);
      const frameSize = major === 4 ? this.syncsafe(fh, 4) : this.be32(fh, 4);
      if (frameSize <= 0) {
        break;
      }
      if (id === 'USLT' || id === 'TXXX') {
        const body = this.readAt(fd, pos + 10, Math.min(frameSize, MAX_TEXT_BYTES));
        const text = id === 'USLT' ? this.parseUslt(body) : this.parseTxxx(body);
        if (text.length > 0) {
          Logger.i(`命中内嵌歌词 ID3v2.${major} ${id}`);
          return text;
        }
      }
      pos += 10 + frameSize;
    }
    return '';
  }

  /** USLT 帧：编码(1) + 语言(3) + 内容描述(0 结尾) + 歌词正文 */
  private parseUslt(body: Uint8Array): string {
    if (body.length < 5) {
      return '';
    }
    const encoding = body[0];
    let pos = 4;
    if (encoding === 1 || encoding === 2) {
      // UTF-16 的描述用两个 0 结尾，且按双字节对齐
      while (pos + 1 < body.length) {
        if (body[pos] === 0 && body[pos + 1] === 0) {
          pos += 2;
          break;
        }
        pos += 2;
      }
    } else {
      while (pos < body.length) {
        if (body[pos] === 0) {
          pos++;
          break;
        }
        pos++;
      }
    }
    const textBytes = body.slice(pos, body.length);
    if (textBytes.length === 0) {
      return '';
    }
    return this.decodeBytes(textBytes, encoding).trim();
  }

  /**
   * TXXX（自定义文本）里也常放歌词。
   * ffmpeg 写 `-metadata lyrics=` 就是落成 description="USLT" 的 TXXX，
   * 所以这里顺带支持，真实世界的 Mp3tag / foobar 一般写正规 USLT 帧。
   */
  private parseTxxx(body: Uint8Array): string {
    if (body.length < 3) {
      return '';
    }
    const encoding = body[0];
    const step = (encoding === 1 || encoding === 2) ? 2 : 1;
    let descEnd = -1;
    for (let i = 1; i + step <= body.length; i += step) {
      if (step === 1) {
        if (body[i] === 0) {
          descEnd = i;
          break;
        }
      } else if (body[i] === 0 && body[i + 1] === 0) {
        descEnd = i;
        break;
      }
    }
    if (descEnd < 0) {
      return '';
    }
    const desc = this.decodeBytes(body.slice(1, descEnd), encoding).trim().toUpperCase();
    const valueStart = descEnd + step;
    if (valueStart >= body.length) {
      return '';
    }
    const value = this.decodeBytes(body.slice(valueStart, body.length), encoding).trim();
    if (desc === 'USLT' || desc === 'LYRICS' || desc === 'UNSYNCEDLYRICS') {
      return value;
    }
    return '';
  }

  /** 按 ID3 的编码字节解码：0=Latin1 1=UTF-16LE 2=UTF-16BE 3=UTF-8 */
  private decodeBytes(bytes: Uint8Array, encoding: number): string {
    if (encoding === 0) {
      return this.latin1(bytes);
    }
    if (encoding === 1) {
      return this.decode(bytes, 'utf-16le');
    }
    if (encoding === 2) {
      return this.decode(bytes, 'utf-16be');
    }
    return this.decode(bytes, 'utf-8');
  }

  // ---------- FLAC ----------

  private fromFlac(fd: number, fileSize: number): string {
    let pos = 4;
    let guard = 0;
    while (pos + 4 <= fileSize && guard < 64) {
      guard++;
      const h = this.readAt(fd, pos, 4);
      if (h.length < 4) {
        break;
      }
      const isLast = (h[0] & 0x80) !== 0;
      const type = h[0] & 0x7F;
      const len = (h[1] << 16) | (h[2] << 8) | h[3];
      if (len < 0 || pos + 4 + len > fileSize) {
        break;
      }
      // 4 = VORBIS_COMMENT
      if (type === 4 && len > 0) {
        const body = this.readAt(fd, pos + 4, Math.min(len, MAX_TAG_BYTES));
        const text = this.parseVorbis(body);
        if (text.length > 0) {
          Logger.i('命中内嵌歌词 FLAC Vorbis Comment');
          return text;
        }
      }
      pos += 4 + len;
      if (isLast) {
        break;
      }
    }
    return '';
  }

  private parseVorbis(body: Uint8Array): string {
    if (body.length < 8) {
      return '';
    }
    let p = 0;
    const vendorLen = this.le32(body, p);
    p += 4 + vendorLen;
    if (p + 4 > body.length) {
      return '';
    }
    const count = this.le32(body, p);
    p += 4;
    for (let i = 0; i < count && p + 4 <= body.length; i++) {
      const len = this.le32(body, p);
      p += 4;
      if (len <= 0 || p + len > body.length) {
        break;
      }
      const entry = this.decode(body.slice(p, p + len), 'utf-8');
      p += len;
      const eq = entry.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const key = entry.substring(0, eq).toUpperCase();
      if (key === 'LYRICS' || key === 'UNSYNCEDLYRICS' || key === 'LYRIC') {
        return entry.substring(eq + 1).trim();
      }
    }
    return '';
  }

  // ---------- MP4 / M4A ----------

  private fromMp4(fd: number, fileSize: number): string {
    // 找 moov，通常在前部（faststart）；没有就放弃
    let pos = 0;
    let guard = 0;
    while (pos + 8 <= fileSize && guard < 32) {
      guard++;
      const h = this.readAt(fd, pos, 8);
      if (h.length < 8) {
        break;
      }
      const size = this.be32(h, 0);
      const type = this.ascii4(h, 4);
      // size == 8 是空 atom（常见 'free'），跳过继续找，别当成结束
      if (size === 8) {
        pos += 8;
        continue;
      }
      if (size < 8) {
        break;
      }
      if (type === 'moov') {
        const readLen = Math.min(size, MAX_TAG_BYTES);
        const body = this.readAt(fd, pos + 8, readLen - 8);
        return this.scanMp4Lyric(body);
      }
      pos += size;
    }
    return '';
  }

  /**
   * 在 moov 里扫 ©lyr。
   * 正经做法是递归解析 atom 树，但这里只找一个固定结构，
   * 直接按字节特征定位更省事，也能容忍一些不规范的文件。
   */
  private scanMp4Lyric(body: Uint8Array): string {
    const target = 0xA9; // ©
    for (let i = 4; i + 12 < body.length; i++) {
      if (body[i] !== target || body[i + 1] !== 0x6C || body[i + 2] !== 0x79 || body[i + 3] !== 0x72) {
        continue;
      }
      // ©lyr 后面紧跟子 atom：[size]['data'][版本/标志 4][locale 4][正文]
      const atomPos = i + 4;
      if (atomPos + 16 > body.length) {
        return '';
      }
      if (!(body[atomPos + 4] === 0x64 && body[atomPos + 5] === 0x61
        && body[atomPos + 6] === 0x74 && body[atomPos + 7] === 0x61)) {
        continue;
      }
      const dataSize = this.be32(body, atomPos);
      const textStart = atomPos + 16;
      const textEnd = Math.min(body.length, atomPos + dataSize);
      if (textEnd <= textStart) {
        return '';
      }
      const text = this.decode(body.slice(textStart, textEnd), 'utf-8').trim();
      if (text.length > 0) {
        Logger.i('命中内嵌歌词 MP4 ©lyr');
        return text;
      }
    }
    return '';
  }

  // ---------- 工具 ----------

  private readAt(fd: number, offset: number, length: number): Uint8Array {
    if (length <= 0) {
      return new Uint8Array(0);
    }
    const buf = new ArrayBuffer(length);
    try {
      const read = fs.readSync(fd, buf, { offset: offset, length: length });
      if (read <= 0) {
        return new Uint8Array(0);
      }
      if (read === length) {
        return new Uint8Array(buf);
      }
      return new Uint8Array(buf.slice(0, read));
    } catch (e) {
      return new Uint8Array(0);
    }
  }

  private syncsafe(b: Uint8Array, off: number): number {
    if (off + 3 >= b.length) {
      return 0;
    }
    return ((b[off] & 0x7F) << 21) | ((b[off + 1] & 0x7F) << 14)
      | ((b[off + 2] & 0x7F) << 7) | (b[off + 3] & 0x7F);
  }

  private be32(b: Uint8Array, off: number): number {
    if (off + 3 >= b.length) {
      return 0;
    }
    return (b[off] << 24 >>> 0) + (b[off + 1] << 16) + (b[off + 2] << 8) + b[off + 3];
  }

  private le32(b: Uint8Array, off: number): number {
    if (off + 3 >= b.length) {
      return 0;
    }
    return b[off] + (b[off + 1] << 8) + (b[off + 2] << 16) + (b[off + 3] * 0x1000000);
  }

  private ascii4(b: Uint8Array, off: number): string {
    if (off + 3 >= b.length) {
      return '';
    }
    return String.fromCharCode(b[off]) + String.fromCharCode(b[off + 1])
      + String.fromCharCode(b[off + 2]) + String.fromCharCode(b[off + 3]);
  }

  private latin1(bytes: Uint8Array): string {
    let out = '';
    for (let i = 0; i < bytes.length; i++) {
      out += String.fromCharCode(bytes[i]);
    }
    return out.trim();
  }

  private decode(bytes: Uint8Array, encoding: string): string {
    try {
      const decoder = util.TextDecoder.create(encoding, { ignoreBOM: true });
      return decoder.decodeToString(bytes);
    } catch (e) {
      try {
        return util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(bytes);
      } catch (e2) {
        return this.latin1(bytes);
      }
    }
  }
}

export const embeddedLyric: EmbeddedLyric = new EmbeddedLyric();
