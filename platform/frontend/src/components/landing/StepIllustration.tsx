const EARTH = "#8a5a2f";
const SEED = "#a8762f";
const LEAF_DARK = "#006b2c";
const LEAF_MID = "#00873a";
const LEAF_LIGHT = "#7ffc97";
const FRUIT = "#f2a14d";
const FRUIT_RIPE = "#d9561f";

function GroundShadow() {
  return (
    <ellipse
      cx="120"
      cy="180"
      rx="64"
      ry="6"
      fill="#3d2a1a"
      opacity="0.14"
    />
  );
}

export function StepIllustration({
  step,
  className = "",
}: {
  step: number;
  className?: string;
}) {
  switch (step) {
    case 0:
      return (
        <svg
          viewBox="0 0 240 200"
          xmlns="http://www.w3.org/2000/svg"
          className={className}
          aria-hidden="true"
        >
          <GroundShadow />
          {/* Soil mound — soft rounded hill, no rectangle */}
          <path
            d="M64 178 Q 120 156, 176 178 Z"
            fill={EARTH}
            opacity="0.55"
          />
          <ellipse cx="120" cy="172" rx="9" ry="6" fill={SEED} />
          <path
            d="M120 172 L120 144"
            stroke={LEAF_MID}
            strokeWidth="2.5"
            fill="none"
            strokeLinecap="round"
          />
          <path
            d="M120 154 Q 104 150, 102 134 Q 116 142, 120 152 Z"
            fill={LEAF_LIGHT}
          />
          <path
            d="M120 154 Q 136 150, 138 134 Q 124 142, 120 152 Z"
            fill={LEAF_MID}
          />
        </svg>
      );

    case 1:
      return (
        <svg
          viewBox="0 0 240 200"
          xmlns="http://www.w3.org/2000/svg"
          className={className}
          aria-hidden="true"
        >
          <GroundShadow />
          <path
            d="M56 178 Q 120 154, 184 178 Z"
            fill={EARTH}
            opacity="0.5"
          />
          <path
            d="M120 174 L120 100"
            stroke="#5c3d20"
            strokeWidth="2.8"
            fill="none"
            strokeLinecap="round"
          />
          <g>
            <path
              d="M120 158 Q 100 154, 92 140 Q 112 146, 120 156 Z"
              fill={LEAF_MID}
            />
            <path
              d="M120 158 Q 140 154, 148 140 Q 128 146, 120 156 Z"
              fill={LEAF_DARK}
            />
            <path
              d="M120 138 Q 98 132, 88 116 Q 112 124, 120 136 Z"
              fill={LEAF_LIGHT}
            />
            <path
              d="M120 138 Q 142 132, 152 116 Q 128 124, 120 136 Z"
              fill={LEAF_MID}
            />
            <path
              d="M120 118 Q 106 110, 104 96 Q 116 106, 120 116 Z"
              fill={LEAF_DARK}
            />
            <path
              d="M120 118 Q 134 110, 136 96 Q 124 106, 120 116 Z"
              fill={LEAF_LIGHT}
            />
          </g>
        </svg>
      );

    case 2:
      return (
        <svg
          viewBox="0 0 240 200"
          xmlns="http://www.w3.org/2000/svg"
          className={className}
          aria-hidden="true"
        >
          <GroundShadow />
          <path
            d="M48 178 Q 120 152, 192 178 Z"
            fill={EARTH}
            opacity="0.5"
          />
          <path
            d="M120 174 L118 74"
            stroke="#5c3d20"
            strokeWidth="3.6"
            fill="none"
            strokeLinecap="round"
          />
          <path
            d="M118 126 L92 104"
            stroke="#5c3d20"
            strokeWidth="2.4"
            strokeLinecap="round"
          />
          <path
            d="M118 126 L146 104"
            stroke="#5c3d20"
            strokeWidth="2.4"
            strokeLinecap="round"
          />
          <ellipse cx="92" cy="96" rx="24" ry="22" fill={LEAF_DARK} />
          <ellipse cx="146" cy="96" rx="26" ry="24" fill={LEAF_MID} />
          <ellipse cx="118" cy="74" rx="32" ry="28" fill={LEAF_DARK} />
          <ellipse
            cx="102"
            cy="86"
            rx="18"
            ry="16"
            fill={LEAF_LIGHT}
            opacity="0.85"
          />
          <ellipse cx="134" cy="86" rx="18" ry="16" fill={LEAF_MID} />
          <g transform="translate(198 46)">
            <circle r="9" fill="#fff6cf" />
            <circle r="5" fill="#ffd56b" />
          </g>
        </svg>
      );

    case 3:
      return (
        <svg
          viewBox="0 0 240 200"
          xmlns="http://www.w3.org/2000/svg"
          className={className}
          aria-hidden="true"
        >
          <GroundShadow />
          <path
            d="M40 178 Q 120 150, 200 178 Z"
            fill={EARTH}
            opacity="0.5"
          />
          <path
            d="M120 174 L118 56"
            stroke="#5c3d20"
            strokeWidth="4.4"
            fill="none"
            strokeLinecap="round"
          />
          <path
            d="M118 116 L84 90"
            stroke="#5c3d20"
            strokeWidth="2.8"
            strokeLinecap="round"
          />
          <path
            d="M118 116 L156 88"
            stroke="#5c3d20"
            strokeWidth="2.8"
            strokeLinecap="round"
          />
          <path
            d="M118 84 L100 64"
            stroke="#5c3d20"
            strokeWidth="2.2"
            strokeLinecap="round"
          />
          <path
            d="M118 84 L138 62"
            stroke="#5c3d20"
            strokeWidth="2.2"
            strokeLinecap="round"
          />
          <ellipse cx="84" cy="84" rx="32" ry="30" fill={LEAF_DARK} />
          <ellipse cx="156" cy="82" rx="34" ry="32" fill={LEAF_MID} />
          <ellipse cx="118" cy="54" rx="42" ry="32" fill={LEAF_DARK} />
          <ellipse
            cx="96"
            cy="72"
            rx="22"
            ry="20"
            fill={LEAF_LIGHT}
            opacity="0.85"
          />
          <ellipse cx="140" cy="72" rx="22" ry="20" fill={LEAF_MID} />
          <g>
            <circle cx="94" cy="88" r="3.5" fill={FRUIT} />
            <circle cx="140" cy="78" r="3.5" fill={FRUIT_RIPE} />
            <circle cx="110" cy="70" r="3.5" fill={FRUIT} />
            <circle cx="128" cy="66" r="3.5" fill={FRUIT_RIPE} />
            <circle cx="82" cy="98" r="3.5" fill={FRUIT_RIPE} />
            <circle cx="156" cy="96" r="3.5" fill={FRUIT} />
            <circle cx="120" cy="88" r="3.5" fill={FRUIT} />
          </g>
        </svg>
      );

    case 4:
      return (
        <svg
          viewBox="0 0 240 200"
          xmlns="http://www.w3.org/2000/svg"
          className={className}
          aria-hidden="true"
        >
          <GroundShadow />
          <path
            d="M40 178 Q 120 152, 200 178 Z"
            fill={EARTH}
            opacity="0.5"
          />
          {/* Parent tree */}
          <g opacity="0.8">
            <path
              d="M84 174 L82 70"
              stroke="#5c3d20"
              strokeWidth="3.5"
              fill="none"
              strokeLinecap="round"
            />
            <path
              d="M82 118 L54 96"
              stroke="#5c3d20"
              strokeWidth="2.2"
              strokeLinecap="round"
            />
            <path
              d="M82 118 L112 94"
              stroke="#5c3d20"
              strokeWidth="2.2"
              strokeLinecap="round"
            />
            <ellipse cx="54" cy="90" rx="24" ry="22" fill={LEAF_DARK} />
            <ellipse cx="112" cy="88" rx="26" ry="24" fill={LEAF_MID} />
            <ellipse cx="82" cy="64" rx="32" ry="26" fill={LEAF_DARK} />
            <ellipse
              cx="70"
              cy="78"
              rx="16"
              ry="14"
              fill={LEAF_LIGHT}
              opacity="0.75"
            />
          </g>
          {/* Seeds arcing */}
          <g fill={FRUIT}>
            <circle cx="126" cy="96" r="2.5" />
            <circle cx="142" cy="114" r="2.5" />
            <circle cx="154" cy="134" r="2.5" />
            <circle cx="164" cy="154" r="2.5" />
          </g>
          {/* New sprout to the right */}
          <g transform="translate(184 174)">
            <path
              d="M-16 2 Q 0 -10, 16 2 Z"
              fill={EARTH}
              opacity="0.5"
            />
            <ellipse cx="0" cy="-2" rx="7" ry="5" fill={SEED} />
            <path
              d="M0 -2 L0 -28"
              stroke={LEAF_MID}
              strokeWidth="2"
              fill="none"
              strokeLinecap="round"
            />
            <path
              d="M0 -14 Q -12 -18 -14 -30 Q -2 -24 0 -16 Z"
              fill={LEAF_LIGHT}
            />
            <path
              d="M0 -14 Q 12 -18 14 -30 Q 2 -24 0 -16 Z"
              fill={LEAF_MID}
            />
          </g>
          <path
            d="M104 60 Q 160 30, 188 140"
            fill="none"
            stroke={LEAF_DARK}
            strokeOpacity="0.3"
            strokeWidth="1.4"
            strokeDasharray="3 5"
          />
        </svg>
      );

    default:
      return null;
  }
}
