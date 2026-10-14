/** Build the entire sequence before sending: never partially type invalid input. */
export function textKeys(text: string, allowControls: boolean): number[] {
  if (!text) throw new Error('Paste or type some text first.');
  const characters = Array.from(text.replace(/\r\n?/g, '\n'));
  if (characters.length > 4096) throw new Error('Send at most 4,096 characters at a time.');
  return characters.map(character => {
    const point = character.codePointAt(0)!;
    if (point === 10 || point === 9) {
      if (!allowControls) throw new Error('Allow line breaks and Tab to send this text. They can submit forms or move focus.');
      return point === 10 ? 0xff0d : 0xff09;
    }
    if (point < 32 || (point >= 127 && point < 160) || (point >= 0xd800 && point <= 0xdfff)) {
      throw new Error('The text contains unsupported control characters.');
    }
    return point <= 0xff ? point : 0x01000000 | point;
  });
}

export async function typeKeys(keys: number[], send: (key: number, down: boolean) => void,
  signal: AbortSignal, progress: (count: number) => void, delay = 20): Promise<number> {
  let count = 0;
  for (const key of keys) {
    if (signal.aborted) break;
    try { send(key, true); } finally { send(key, false); }
    count++;
    progress(count);
    await new Promise<void>(resolve => {
      const done = () => { clearTimeout(timer); signal.removeEventListener('abort', done); resolve(); };
      const timer = setTimeout(done, delay);
      signal.addEventListener('abort', done, { once: true });
      if (signal.aborted) done();
    });
  }
  return count;
}
