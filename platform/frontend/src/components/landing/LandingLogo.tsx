type LogoProps = {
  className?: string;
  variant?: "dark" | "light";
};

const GREEN = "#00873a";
const GREEN_DEEP = "#006b2c";

export function LandingLogo({ className = "", variant = "dark" }: LogoProps) {
  const ink = variant === "dark" ? "#000000" : "#ffffff";
  const stroke = variant === "dark" ? "#191c1e" : "#ffffff";
  return (
    <span
      className={`inline-flex items-center gap-2.5 ${className}`}
      style={{ color: ink, fontFamily: "var(--font-header)", fontWeight: 700 }}
    >
      <svg
        width="32"
        height="32"
        viewBox="0 0 88 88"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
        aria-hidden="true"
      >
        <circle
          cx="44"
          cy="44"
          r="42"
          fill="none"
          stroke={stroke}
          strokeWidth="3"
        />
        <path
          d="M 26 56 Q 26 32 44 26 Q 44 50 26 56 Z"
          fill={GREEN}
        />
        <path
          d="M 62 32 Q 62 56 44 62 Q 44 38 62 32 Z"
          fill={GREEN_DEEP}
        />
      </svg>
      <span className="text-3xl leading-none tracking-tight">GrowFi</span>
    </span>
  );
}
