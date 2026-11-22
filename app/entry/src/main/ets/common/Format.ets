/** 毫秒 → mm:ss */
export function formatTime(ms: number): string {
  if (ms <= 0) {
    return '00:00';
  }
  const total = Math.floor(ms / 1000);
  const m = Math.floor(total / 60);
  const s = total % 60;
  const mm = m < 10 ? `0${m}` : `${m}`;
  const ss = s < 10 ? `0${s}` : `${s}`;
  return `${mm}:${ss}`;
}

/** 字节 → 1.2 MB */
export function formatSize(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  const kb = bytes / 1024;
  if (kb < 1024) {
    return `${kb.toFixed(0)} KB`;
  }
  const mb = kb / 1024;
  return `${mb.toFixed(1)} MB`;
}

/** 取小写扩展名，不含点 */
export function extensionOf(name: string): string {
  const dot = name.lastIndexOf('.');
  if (dot < 0 || dot === name.length - 1) {
    return '';
  }
  return name.substring(dot + 1).toLowerCase();
}

/** 去掉扩展名的文件名 */
export function stemOf(name: string): string {
  const dot = name.lastIndexOf('.');
  if (dot <= 0) {
    return name;
  }
  return name.substring(0, dot);
}
