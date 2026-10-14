import { useState, type MouseEvent } from 'react';
import { fmtDate, timeFmt } from '../format';

export interface ChartSeries<T> {
  label: string;
  /** CSS class giving the line its color (series-a, series-b, series-c). */
  cls: string;
  value: (sample: T) => number | null;
}

const W = 600, H = 100;

/**
 * Line chart over a fixed time window. Gaps longer than 2.5 steps (VM stopped, app not running) break
 * the lines. Hovering shows the values at that time.
 */
export function LineChart<T extends { t: number }>({ title, samples, series, format, max, start, end, step }: {
  title: string;
  samples: T[];
  series: ChartSeries<T>[];
  format: (value: number) => string;
  /** Fixed y maximum (e.g. 1 for a share); otherwise scaled to the data. */
  max?: number;
  start: number;
  end: number;
  /** Milliseconds between samples. */
  step: number;
}) {
  const [hover, setHover] = useState<number | null>(null);
  const values = samples.flatMap((s) => series.map((x) => x.value(s))).filter((v): v is number => v != null && Number.isFinite(v));
  const top = max ?? (Math.max(...values, 0) * 1.15 || 1);
  const span = Math.max(end - start, 1);
  const x = (t: number) => ((t - start) / span) * W;
  const y = (v: number) => H - Math.min(1, Math.max(0, v / top)) * H;

  const lines = series.map((s) => {
    const segments: string[][] = [];
    let last: number | null = null;
    for (const sample of samples) {
      const v = s.value(sample);
      if (v == null || !Number.isFinite(v)) { last = null; continue; }
      if (last == null || sample.t - last > step * 2.5) segments.push([]);
      segments[segments.length - 1].push(`${x(sample.t).toFixed(1)},${y(v).toFixed(1)}`);
      last = sample.t;
    }
    return segments;
  });

  const latest = samples[samples.length - 1];
  const shown = hover != null ? samples[hover] : latest;
  const onMove = (e: MouseEvent<SVGSVGElement>) => {
    if (!samples.length) return;
    const rect = e.currentTarget.getBoundingClientRect();
    const t = start + ((e.clientX - rect.left) / rect.width) * span;
    let best = 0;
    for (let i = 1; i < samples.length; i++) if (Math.abs(samples[i].t - t) < Math.abs(samples[best].t - t)) best = i;
    setHover(Math.abs(samples[best].t - t) < step * 3 ? best : null);
  };

  return (
    <figure className="chart metric">
      <div className="chart-head">
        <strong>{title}</strong>
        <span className="legend">
          {series.map((s) => {
            const v = shown ? s.value(shown) : null;
            return <span key={s.label}><i className={s.cls} />{s.label} <strong>{v == null ? '—' : format(v)}</strong></span>;
          })}
          {hover != null && shown && <span className="muted">{fmtDate(new Date(shown.t).toISOString(), timeFmt)}</span>}
        </span>
      </div>
      <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" aria-label={title} onMouseMove={onMove} onMouseLeave={() => setHover(null)}>
        {[0.25, 0.5, 0.75].map((f) => <line key={f} className="grid" x1="0" x2={W} y1={H * f} y2={H * f} />)}
        {lines.map((segments, i) => segments.map((points, j) => points.length > 1
          ? <polyline key={`${i}-${j}`} className={`line ${series[i].cls}`} points={points.join(' ')} />
          : <circle key={`${i}-${j}`} className={`point ${series[i].cls}`} cx={points[0].split(',')[0]} cy={points[0].split(',')[1]} r="1.5" />))}
        {hover != null && samples[hover] && <line className="cursor" x1={x(samples[hover].t)} x2={x(samples[hover].t)} y1="0" y2={H} />}
      </svg>
      <figcaption className="muted small">
        <span>{format(top)}</span>
        {!samples.length && <span>No data yet</span>}
      </figcaption>
    </figure>
  );
}
