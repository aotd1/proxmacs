/** Track only currently held keys, never text history. noVNC uses this public method for physical keys too. */
export function trackConsoleKeys(client: { viewOnly: boolean; sendKey: (key: number, code?: string, down?: boolean) => void }): () => void {
  const send = client.sendKey.bind(client);
  const held = new Map<string | number, { key: number; code?: string }>();
  client.sendKey = (key, code, down) => {
    if (!client.viewOnly && down !== undefined) {
      const id = code ?? key;
      if (down) held.set(id, { key, code });
      else held.delete(id);
    }
    send(key, code, down);
  };
  return () => {
    for (const { key, code } of held.values()) send(key, code, false);
    held.clear();
  };
}
