import type { QuotaFileEntry } from './logic';
import type { QuotaCardState } from './providers';
import { buildTimelineLane } from './quotaTimelineModel';

/** Redact addresses wherever they appear, including addresses embedded in filenames. */
export function maskQuotaIdentity(value: string): string {
  return value.replace(
    /([\w.+-]+)@([\w.-]+\.[a-z]{2,})/gi,
    (_match, local: string, domain: string) => {
      const prefix =
        local.match(/^(?:claude|codex|antigravity|xai|kimi|devin|meta)-(?:[a-f0-9]{8}-)?/i)?.[0] ??
        '';
      const filenameSuffix = domain.match(/(?:-(?:pro|plus|max|team|free))?\.json$/i)?.[0] ?? '';
      const parts = (filenameSuffix ? domain.slice(0, -filenameSuffix.length) : domain).split('.');
      const suffix = parts.pop();
      return `${prefix}${local.slice(prefix.length, prefix.length + 1)}•••@${parts.map((part) => `${part.slice(0, 1)}•••`).join('.')}.${suffix}${filenameSuffix}`;
    }
  );
}

/** Aggregate the same quota period only; unknown credentials never count as full or empty. */
export function summarizeQuotaEntries(
  entries: QuotaFileEntry[],
  quotaFor: (entry: QuotaFileEntry) => QuotaCardState | undefined
) {
  const lanes = entries.map((entry) =>
    buildTimelineLane({
      name: entry.file.name,
      displayName: '',
      provider: entry.type,
      quota: quotaFor(entry),
    })
  );
  const periods = lanes.flatMap((lane) =>
    lane.periodHours !== null && lane.remaining !== null && Number.isFinite(lane.remaining)
      ? [lane.periodHours]
      : []
  );
  const periodHours = periods.length ? Math.max(...periods) : null;
  const segments = lanes.map((lane) =>
    lane.periodHours === periodHours && lane.remaining !== null && Number.isFinite(lane.remaining)
      ? lane.remaining
      : null
  );
  const known = segments.filter((percent): percent is number => percent !== null);
  const resets = lanes.flatMap((lane, index) =>
    segments[index] !== null && lane.anchorMs !== null ? [lane.anchorMs] : []
  );
  return {
    total: known.length ? known.reduce((sum, percent) => sum + percent, 0) : null,
    capacity: known.length * 100,
    knownCount: known.length,
    periodHours,
    segments,
    resetAtMs: resets.length ? Math.min(...resets) : null,
  };
}
