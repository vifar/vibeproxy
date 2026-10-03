import type { QuotaClassMap } from '../types';

export interface QuotaCreditDetail {
  label: string;
  value: string;
  hint?: string;
}

export function QuotaCreditDetails({
  items,
  classes,
}: {
  items: QuotaCreditDetail[];
  classes: QuotaClassMap;
}) {
  return (
    <dl className={classes.quotaCredits}>
      {items.map((item) => (
        <div key={item.label} className={classes.quotaCreditItem}>
          <dt className={classes.quotaCreditLabel}>{item.label}</dt>
          <dd className={classes.quotaCreditValue}>{item.value}</dd>
          {item.hint && <dd className={classes.quotaCreditHint}>{item.hint}</dd>}
        </div>
      ))}
    </dl>
  );
}
