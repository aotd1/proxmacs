import { useCallback, useEffect, useState } from 'react';
import { api, AuthError, errorMessage } from '../../api';
import { ActionButton, Badge, Empty, Loading, Panel } from '../../components/ui';
import type { Image } from '../../types';

export function ImagesView() {
  const [images, setImages] = useState<Image[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setImages(await api<Image[]>('GET', '/api/images'));
      setError(null);
    } catch (e) {
      if (!(e instanceof AuthError)) setError(errorMessage(e));
    }
  }, []);
  useEffect(() => { void load(); }, [load]);

  return (
    <>
      <Panel title="Images" flush extra={<ActionButton className="small" onClick={load}>Refresh</ActionButton>}>
        {error ? <Empty error>{error}</Empty> : !images ? <Loading /> : !images.length ? <Empty>No images.</Empty> : (
          <table className="table">
            <thead><tr><th>Name</th><th>ID</th><th>Cached</th></tr></thead>
            <tbody>
              {images.map((img) => (
                <tr key={img.id}>
                  <td>{img.name || img.id}</td>
                  <td className="mono muted wrap">{img.id}</td>
                  <td>{img.cached ? <Badge kind="ok">cached</Badge> : <Badge>not downloaded</Badge>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Panel>
      <p className="muted small">Images are downloaded on first use when creating a VM and cached on this Mac.</p>
    </>
  );
}
