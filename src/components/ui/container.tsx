import { ReactNode } from "react";

interface ContainerProps {
  children: ReactNode;
  className?: string;
}

export function Container({ children, className = "" }: ContainerProps) {
  return (
    <div
      style={{
        maxWidth: "var(--container-max)",
        marginLeft: "auto",
        marginRight: "auto",
        paddingLeft: "var(--container-px)",
        paddingRight: "var(--container-px)",
      }}
      className={className}
    >
      {children}
    </div>
  );
}
