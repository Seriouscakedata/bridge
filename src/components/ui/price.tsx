interface PriceProps {
  cents: number;
  className?: string;
}

export function formatPrice(cents: number): string {
  return `${Math.round(cents / 100)} грн`;
}

export function Price({ cents, className }: PriceProps) {
  return <span className={className}>{formatPrice(cents)}</span>;
}
