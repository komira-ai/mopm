/**
 * CloudWatch embedded-metric-format lines. A Lambda writes one JSON line to its log and CloudWatch extracts the
 * metrics from it, so emitting a metric needs no API call and no IAM permission.
 * Format: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Embedded_Metric_Format_Specification.html
 */

export const METRICS_NAMESPACE = 'Mopm/Registry';

export type MetricUnit = 'Count' | 'Milliseconds' | 'Seconds' | 'Bytes' | 'None';

export interface Metric {
  name: string;
  value: number;
  unit?: MetricUnit;
}

/** Where finished lines go. The default writes them to the function's log. */
export type LineSink = (line: Record<string, unknown>) => void;

export const consoleSink: LineSink = (line) => console.log(JSON.stringify(line));

/**
 * One EMF line: the metrics, the dimensions (string values; one dimension set holding all of them), and `props`,
 * which are searchable log fields and not metrics. A line with no metric is not a metric line, so `emf` refuses it.
 */
export function emf(metrics: readonly Metric[], opts: { dimensions?: Record<string, string>; props?: Record<string, unknown>; now?: Date } = {}): Record<string, unknown> {
  if (metrics.length === 0) throw new Error('emf: a metric line needs at least one metric');
  const dimensions = opts.dimensions ?? {};
  const names = new Set<string>();
  for (const m of metrics) {
    if (names.has(m.name)) throw new Error(`emf: metric ${m.name} appears twice in one line`);
    names.add(m.name);
    if (!Number.isFinite(m.value)) throw new Error(`emf: metric ${m.name} is not a finite number`);
  }
  return {
    ...opts.props,
    ...dimensions,
    ...Object.fromEntries(metrics.map((m) => [m.name, m.value])),
    _aws: {
      Timestamp: (opts.now ?? new Date()).getTime(),
      CloudWatchMetrics: [
        {
          Namespace: METRICS_NAMESPACE,
          Dimensions: [Object.keys(dimensions)],
          Metrics: metrics.map((m) => ({ Name: m.name, Unit: m.unit ?? 'Count' })),
        },
      ],
    },
  };
}

/** Emits metric lines to a sink. Never throws: a metric must not fail the request it describes. */
export class Metrics {
  constructor(
    private readonly sink: LineSink = consoleSink,
    private readonly dimensions: Record<string, string> = {},
    private readonly now: () => Date = () => new Date(),
  ) {}

  emit(metrics: readonly Metric[], props: Record<string, unknown> = {}): void {
    if (metrics.length === 0) return;
    try {
      this.sink(emf(metrics, { dimensions: this.dimensions, props, now: this.now() }));
    } catch {
      // A broken sink or a bad value is dropped on purpose.
    }
  }

  count(name: string, value = 1, props: Record<string, unknown> = {}): void {
    this.emit([{ name, value }], props);
  }
}
