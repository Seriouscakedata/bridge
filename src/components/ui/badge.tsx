interface BadgeProps {
  label: string;
  variant?: "default" | "new" | "popular" | "vegetarian" | "dessert";
}

const variantStyles: Record<string, React.CSSProperties> = {
  default:    { background: "#e5e5e3", color: "#6b6b67" },
  new:        { background: "#fef3c7", color: "#92400e" },
  popular:    { background: "#fee2e2", color: "#991b1b" },
  vegetarian: { background: "#d1fae5", color: "#065f46" },
  dessert:    { background: "#ede9fe", color: "#5b21b6" },
};

const labelMap: Record<string, string> = {
  new:        "Новинка",
  popular:    "Хит",
  vegetarian: "Вегетарианское",
  dessert:    "Десерт",
};

export function Badge({ label, variant = "default" }: BadgeProps) {
  const display = labelMap[label] ?? label;
  return (
    <span
      style={{
        display: "inline-block",
        padding: "2px 10px",
        borderRadius: 999,
        fontSize: 12,
        fontWeight: 600,
        ...variantStyles[variant] ?? variantStyles.default,
      }}
    >
      {display}
    </span>
  );
}
