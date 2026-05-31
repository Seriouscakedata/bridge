import { ButtonHTMLAttributes, ReactNode } from "react";

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: "primary" | "outline" | "ghost";
  size?: "sm" | "md" | "lg";
  children: ReactNode;
}

const styles: Record<string, React.CSSProperties> = {
  base: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    borderRadius: "var(--radius-md)",
    fontWeight: 600,
    cursor: "pointer",
    transition: "background 0.15s, color 0.15s, border-color 0.15s",
    border: "2px solid transparent",
    whiteSpace: "nowrap",
  },
  primary: {
    background: "var(--color-brand)",
    color: "var(--color-text-inverse)",
    borderColor: "var(--color-brand)",
  },
  outline: {
    background: "transparent",
    color: "var(--color-brand)",
    borderColor: "var(--color-brand)",
  },
  ghost: {
    background: "transparent",
    color: "var(--color-text)",
    borderColor: "transparent",
  },
  sm: { padding: "6px 14px", fontSize: 14 },
  md: { padding: "10px 20px", fontSize: 16 },
  lg: { padding: "14px 28px", fontSize: 18 },
};

export function Button({
  variant = "primary",
  size = "md",
  style,
  children,
  ...props
}: ButtonProps) {
  return (
    <button
      style={{ ...styles.base, ...styles[variant], ...styles[size], ...style }}
      {...props}
    >
      {children}
    </button>
  );
}
