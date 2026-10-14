import { useCallback, useState } from 'react';
import { api, AuthError, enc, errorMessage } from '../../api';
import { useConfirm } from '../../components/Modal';
import { useToast } from '../../components/Toasts';
import { ActionButton, Badge, Empty, Loading, Panel, Spinner } from '../../components/ui';
import { fmtBytes } from '../../format';
import { usePoller } from '../../hooks';
import { useApp } from '../../store';
import type { Image } from '../../types';

export function ImagesView() {
  const app = useApp();
  const confirm = useConfirm();
  const { toast } = useToast();
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
  // Faster while something downloads, so progress moves.
  const reload = usePoller(load, images?.some((i) => i.downloading) ? 1500 : 10000);

  const download = async (image: Image) => {
    await app.startTask('POST', `/api/images/${enc(image.id)}/download`, {}, `Download ${image.name}`);
    reload();
  };

  const remove = async (image: Image) => {
    const ok = await confirm({
      title: 'Delete image',
      message: image.imported
        ? `Delete the imported image “${image.name}”? Existing VMs are not affected.`
        : `Delete the cached ${image.name} image? Existing VMs are not affected, and it is downloaded again when needed.`,
      confirmLabel: 'Delete', danger: true,
    });
    if (!ok) return;
    await api('DELETE', `/api/images/${enc(image.id)}`, {});
    toast(`${image.name} deleted`, 'ok');
    reload();
  };

  const catalog = images?.filter((i) => !i.imported) ?? [];
  const imported = images?.filter((i) => i.imported) ?? [];
  const used = images?.reduce((sum, i) => sum + (i.diskBytes ?? 0), 0) ?? 0;

  const actions = (image: Image) => (
    <td className="actions-cell">
      <div className="actions">
        {!image.cached && !image.downloading && <ActionButton className="small" onClick={() => download(image)}>Download</ActionButton>}
        {image.cached && <ActionButton className="small danger" onClick={() => remove(image)}>Delete</ActionButton>}
      </div>
    </td>
  );
  const size = (image: Image) => (
    <td className="nowrap wide-only">
      {image.cached ? <>{fmtBytes(image.diskBytes)}<div className="small muted" title="Disk size of the image: the smallest disk a VM from it can have">{fmtBytes(image.sizeBytes)} virtual</div></> : '—'}
    </td>
  );

  return (
    <>
      <Panel title="Cloud images" flush extra={images && used > 0 && <span className="muted small">{fmtBytes(used)} cached</span>}>
        {error ? <Empty error>{error}</Empty> : !images ? <Loading /> : (
          <table className="table">
            <thead><tr><th>Image</th><th className="wide-only">User</th><th className="wide-only">Size</th><th>Status</th><th /></tr></thead>
            <tbody>
              {catalog.map((image) => (
                <tr key={image.id}>
                  <td>
                    <strong>{image.name}</strong>
                    {image.url && <div className="small muted wrap wide-only">{new URL(image.url).host}</div>}
                  </td>
                  <td className="wide-only mono">{image.user}</td>
                  {size(image)}
                  <td>
                    {image.downloading ? (
                      <div className="image-progress" title={image.downloading.message}>
                        <span className="task-status"><Spinner />{image.downloading.message}</span>
                        {image.downloading.progress != null && (
                          <div className="progress"><div style={{ width: `${Math.round(image.downloading.progress * 100)}%` }} /></div>
                        )}
                      </div>
                    ) : image.cached ? <Badge kind="ok">cached</Badge> : <span className="muted">not downloaded</span>}
                  </td>
                  {actions(image)}
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Panel>
      {imported.length > 0 && (
        <Panel title="Imported images" flush>
          <table className="table">
            <thead><tr><th>File</th><th className="wide-only">Size</th><th /></tr></thead>
            <tbody>
              {imported.map((image) => (
                <tr key={image.id}>
                  <td className="mono wrap">{image.name}</td>
                  {size(image)}
                  {actions(image)}
                </tr>
              ))}
            </tbody>
          </table>
        </Panel>
      )}
      <p className="muted small prose">
        Images are arm64 cloud images, converted to sparse raw disks and cached on this Mac. Download one ahead of time so
        creating a VM from it doesn’t wait; otherwise it is downloaded the first time a VM uses it. Deleting a cached image
        doesn’t affect VMs created from it. Images imported from a file (menubar or <span className="mono">cli create --image</span>)
        are listed separately.
      </p>
    </>
  );
}
