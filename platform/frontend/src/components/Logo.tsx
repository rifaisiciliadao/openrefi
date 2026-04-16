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
      {/* Leaf / seedling icon */}
      <g transform="translate(0, 2)">
        {/* Stem */}
        <path
          d="M16 30C16 30 16 20 16 16"
          stroke="#2d6a2e"
          strokeWidth="3"
          strokeLinecap="round"
        />
        {/* Left leaf */}
        <path
          d="M16 18C16 18 6 16 4 8C4 8 14 6 16 14"
          fill="#2d6a2e"
        />
        {/* Right leaf */}
        <path
          d="M16 12C16 12 24 9 28 2C28 2 18 1 16 8"
          fill="#2d6a2e"
        />
      </g>
      {/* GrowFi text */}
      <text
        x="40"
        y="26"
        fontFamily="Inter, sans-serif"
        fontWeight="800"
        fontSize="24"
        fill="#2d6a2e"
        letterSpacing="-0.5"
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
      viewBox="0 0 32 32"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <path
        d="M16 28C16 28 16 18 16 14"
        stroke="#2d6a2e"
        strokeWidth="3"
        strokeLinecap="round"
      />
      <path
        d="M16 16C16 16 6 14 4 6C4 6 14 4 16 12"
        fill="#2d6a2e"
      />
      <path
        d="M16 10C16 10 24 7 28 0C28 0 18 -1 16 6"
        fill="#2d6a2e"
      />
    </svg>
  );
}
