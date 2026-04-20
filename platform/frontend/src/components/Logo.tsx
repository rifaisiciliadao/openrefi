// New GrowFi mark: outlined circle containing two opposing leaves.
// Source: graphics/logos.jsx Logo08 + AppIcon(leaf). Colors map to the
// site primary palette (#006b2c deep, #00873a mid).

const INK = "#191c1e";
const GREEN = "#00873a";
const GREEN_DEEP = "#006b2c";

export function Logo({ className = "" }: { className?: string }) {
  return (
    <svg
      width="160"
      height="36"
      viewBox="0 0 160 36"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      className={className}
    >
      <g transform="translate(0,0) scale(0.409)">
        <circle
          cx="44"
          cy="44"
          r="42"
          fill="none"
          stroke={INK}
          strokeWidth="2.5"
        />
        <path
          d="M 26 56 Q 26 32 44 26 Q 44 50 26 56 Z"
          fill={GREEN}
        />
        <path
          d="M 62 32 Q 62 56 44 62 Q 44 38 62 32 Z"
          fill={GREEN_DEEP}
        />
      </g>
      <text
        x="46"
        y="26"
        fontFamily='"Inter Tight", Inter, sans-serif'
        fontWeight="700"
        fontSize="24"
        fill={INK}
        letterSpacing="-1"
      >
        GrowFi
      </text>
    </svg>
  );
}

export function LogoIcon({ size = 32 }: { size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 88 88"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <circle
        cx="44"
        cy="44"
        r="42"
        fill="none"
        stroke={INK}
        strokeWidth="2.5"
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
  );
}
