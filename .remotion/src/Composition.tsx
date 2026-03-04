import {
  AbsoluteFill,
  interpolate,
  spring,
  useCurrentFrame,
  Sequence,
  Easing,
} from "remotion";
// ─── palette ───────────────────────────────────────────────────────────────
const BG      = "#06060e";
const CYAN    = "#00d4ff";
const ORANGE  = "#ff6b35";
const PURPLE  = "#8b5cf6";
const OFFWHITE = "#f0ede6";   // warm off-white for all text
const MUTED   = "#a09890";    // dimmed off-white
const DIM     = "#ffffff14";

// ─── timing helpers ─────────────────────────────────────────────────────────
const clamp = (v: number) => Math.max(0, Math.min(1, v));

const lerp = (
  frame: number,
  from: number,
  to: number,
  easing: (t: number) => number = (t) => t
) => {
  const t = clamp((frame - from) / (to - from));
  return easing(t);
};

const easeOut = Easing.out(Easing.cubic);

const fadeIn  = (f: number, start: number, dur = 24) => lerp(f, start, start + dur, easeOut);
const fadeOut = (f: number, start: number, dur = 18) => 1 - lerp(f, start, start + dur, easeOut);

// ─── Scanlines overlay ──────────────────────────────────────────────────────
const Scanlines: React.FC<{ color?: string; opacity?: number }> = ({
  color = CYAN, opacity = 0.03,
}) => (
  <div style={{
    position: "absolute", inset: 0, pointerEvents: "none",
    backgroundImage: `repeating-linear-gradient(0deg, transparent, transparent 3px, ${color}${Math.round(opacity * 255).toString(16).padStart(2, "0")} 3px, ${color}${Math.round(opacity * 255).toString(16).padStart(2, "0")} 4px)`,
  }} />
);

// ─── Scene 1: codedb cold open  (0–100) ─────────────────────────────────────
const CodedbScene: React.FC<{ frame: number }> = ({ frame }) => {
  const chars = "codedb".split("").map((ch, i) => {
    const op = lerp(frame, i * 6, i * 6 + 12, easeOut);
    const glitch = frame > 78 && frame < 95
      ? Math.abs(Math.sin(frame * 9 + i * 2.3)) * 0.6 + 0.4
      : 1;
    return (
      <span key={i} style={{ opacity: op * glitch, display: "inline-block",
        color: frame > 78 ? `hsl(${190 + i * 8}, 100%, 65%)` : CYAN }}>
        {ch}
      </span>
    );
  });

  const cursor = Math.floor(frame / 10) % 2 === 0;
  const subOp  = fadeIn(frame, 52, 22);
  const sceneOut = frame > 82 ? fadeOut(frame, 82, 18) : 1;

  return (
    <AbsoluteFill style={{
      background: BG,
      display: "flex", flexDirection: "column",
      alignItems: "center", justifyContent: "center",
      opacity: sceneOut,
    }}>
      <Scanlines />
      {/* ambient glow */}
      <div style={{
        position: "absolute", width: 700, height: 700, borderRadius: "50%",
        background: `radial-gradient(ellipse, ${CYAN}12 0%, transparent 65%)`,
        pointerEvents: "none",
      }} />

      <div style={{
        fontFamily: "'Courier New', Courier, monospace",
        fontSize: 148,
        fontWeight: 700,
        letterSpacing: "0.18em",
        color: CYAN,
        textShadow: `0 0 50px ${CYAN}99, 0 0 100px ${CYAN}44, 0 0 200px ${CYAN}22`,
        lineHeight: 1,
      }}>
        {chars}
        <span style={{ opacity: cursor ? 0.9 : 0, color: CYAN }}>_</span>
      </div>

      <div style={{
        fontFamily: "'Courier New', monospace",
        fontSize: 22, letterSpacing: "0.45em",
        color: MUTED, marginTop: 36,
        opacity: subOp, textTransform: "uppercase",
      }}>
        a new kind of dev tool
      </div>
    </AbsoluteFill>
  );
};

// ─── Scene 2: rename reveal  (95–210) ───────────────────────────────────────
const RenameScene: React.FC<{ frame: number }> = ({ frame }) => {
  const sceneIn  = fadeIn(frame, 0, 22);
  const sceneOut = frame > 95 ? fadeOut(frame, 95, 16) : 1;

  const oldX  = interpolate(frame, [0, 28], [0, -100], { extrapolateRight: "clamp", easing: Easing.in(Easing.cubic) });
  const oldOp = 1 - lerp(frame, 0, 28, easeOut);

  const newX  = interpolate(frame, [20, 52], [120, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: Easing.out(Easing.back(1.3)) });
  const newOp = lerp(frame, 20, 52, easeOut);

  const subOp  = fadeIn(frame, 56, 24);
  const top5Op = fadeIn(frame, 72, 24);
  const tagOp  = fadeIn(frame, 85, 20);

  return (
    <AbsoluteFill style={{
      background: BG,
      display: "flex", flexDirection: "column",
      alignItems: "center", justifyContent: "center",
      opacity: sceneIn * sceneOut,
    }}>
      <Scanlines />
      <div style={{
        position: "absolute", width: 900, height: 500, borderRadius: "50%",
        background: `radial-gradient(ellipse, ${CYAN}0e 0%, transparent 70%)`,
      }} />

      {/* name swap */}
      <div style={{ position: "relative", height: 180, display: "flex", alignItems: "center", justifyContent: "center", width: "100%" }}>
        <div style={{
          position: "absolute",
          fontFamily: "'Courier New', monospace",
          fontSize: 120, fontWeight: 700, letterSpacing: "0.14em",
          color: `${CYAN}55`,
          transform: `translateX(${oldX}px)`, opacity: oldOp,
          textDecoration: "line-through",
          textDecorationColor: `${CYAN}66`,
        }}>codedb</div>

        <div style={{
          fontFamily: "'Courier New', monospace",
          fontSize: 148, fontWeight: 700, letterSpacing: "0.14em",
          color: CYAN,
          transform: `translateX(${newX}px)`, opacity: newOp,
          textShadow: `0 0 60px ${CYAN}aa, 0 0 120px ${CYAN}55`,
        }}>devswarm</div>
      </div>

      <div style={{
        fontFamily: "'Courier New', monospace",
        fontSize: 26, letterSpacing: "0.25em",
        color: OFFWHITE, marginTop: 40, opacity: subOp,
      }}>
        built in <span style={{ color: ORANGE, fontWeight: 700 }}>8 hours</span>
      </div>

      <div style={{
        fontFamily: "'Courier New', monospace",
        fontSize: 22, letterSpacing: "0.35em",
        color: MUTED, marginTop: 18, opacity: top5Op,
      }}>
        ★&nbsp;&nbsp;placed&nbsp;&nbsp;<span style={{ color: OFFWHITE }}>top 5</span>&nbsp;&nbsp;at the hackathon
      </div>

      <div style={{
        display: "flex", gap: 14, marginTop: 36, opacity: tagOp,
      }}>
        {["#zig", "#mcp", "#ai", "#devtools"].map((t) => (
          <span key={t} style={{
            fontFamily: "'Courier New', monospace", fontSize: 14,
            color: MUTED, letterSpacing: "0.1em",
            border: `1px solid ${OFFWHITE}18`,
            padding: "6px 14px",
          }}>{t}</span>
        ))}
      </div>
    </AbsoluteFill>
  );
};

// ─── Scene 3: CodeGraph  (205–345) ──────────────────────────────────────────

const GraphScene: React.FC<{ frame: number }> = ({ frame }) => {
  const W = 1920, H = 1080;
  const sceneIn  = fadeIn(frame, 0, 30);
  const sceneOut = frame > 110 ? fadeOut(frame, 112, 16) : 1;

  // Spread nodes much further apart, keep center node in middle
  const GNODES = [
    { x: 0.5,  y: 0.5,  label: "your repo",       main: true  },
    { x: 0.18, y: 0.22, label: "blast_radius",     main: false },
    { x: 0.76, y: 0.18, label: "symbol_at",        main: false },
    { x: 0.10, y: 0.65, label: "relevant_context", main: false },
    { x: 0.84, y: 0.70, label: "CodeGraph",        main: false },
    { x: 0.48, y: 0.08, label: "call edges",       main: false },
    { x: 0.58, y: 0.88, label: "PageRank",         main: false },
    { x: 0.26, y: 0.82, label: "dependencies",     main: false },
    { x: 0.90, y: 0.38, label: "PRs / Issues",     main: false },
    { x: 0.14, y: 0.40, label: "file map",         main: false },
  ];

  const GEDGES = [
    [0,1],[0,2],[0,3],[0,4],[0,5],[0,6],[0,7],[0,8],[0,9],
    [1,3],[2,5],[4,6],[8,4],
  ];

  return (
    <AbsoluteFill style={{ background: BG, opacity: sceneIn * sceneOut }}>
      <Scanlines opacity={0.02} />

      <svg width={W} height={H} style={{ position: "absolute", inset: 0 }}>
        {/* subtle grid */}
        {Array.from({ length: 19 }).map((_, i) => (
          <line key={`h${i}`} x1={0} y1={i * 60} x2={W} y2={i * 60}
            stroke={DIM} strokeWidth={0.5} />
        ))}
        {Array.from({ length: 33 }).map((_, i) => (
          <line key={`v${i}`} x1={i * 60} y1={0} x2={i * 60} y2={H}
            stroke={DIM} strokeWidth={0.5} />
        ))}

        {/* edges */}
        {GEDGES.map(([a, b], i) => {
          const n1 = GNODES[a], n2 = GNODES[b];
          const delay = i * 4;
          const op = lerp(frame, delay, delay + 24, easeOut);
          const x1 = n1.x * W, y1 = n1.y * H;
          const x2 = n2.x * W, y2 = n2.y * H;
          const len = Math.sqrt((x2-x1)**2 + (y2-y1)**2);
          return (
            <line key={i} x1={x1} y1={y1} x2={x2} y2={y2}
              stroke={CYAN} strokeWidth={2.5} opacity={0.6 * op}
              strokeDasharray={`${len * op} ${len}`} />
          );
        })}

        {/* nodes */}
        {GNODES.map((n, i) => {
          const delay = i * 7;
          const sc = spring({ frame: frame - delay, fps: 30, config: { damping: 14, stiffness: 160 } });
          const nx = n.x * W, ny = n.y * H;
          const r = n.main ? 44 : 26;
          const pulse = n.main ? r + 10 + Math.sin(frame * 0.11) * 8 : r;
          const labelW = n.label.length * 16 + 28;
          return (
            <g key={i} transform={`translate(${nx},${ny}) scale(${sc})`}>
              {n.main && <>
                <circle r={pulse + 30} fill="none" stroke={CYAN} strokeWidth={1} opacity={0.1} />
                <circle r={pulse} fill="none" stroke={CYAN} strokeWidth={1.5} opacity={0.2} />
              </>}
              <circle r={r}
                fill={n.main ? CYAN : `${CYAN}33`}
                stroke={CYAN} strokeWidth={n.main ? 0 : 2.5}
                style={{ filter: `drop-shadow(0 0 ${n.main ? 40 : 18}px ${CYAN})` }} />
              {/* label pill */}
              {!n.main && (
                <rect
                  x={-labelW / 2} y={r + 12}
                  width={labelW} height={38}
                  rx={5}
                  fill={BG}
                  opacity={0.85}
                />
              )}
              <text y={n.main ? r + 46 : r + 38} textAnchor="middle"
                fontFamily="'Courier New', monospace"
                fontSize={n.main ? 32 : 26}
                fill={OFFWHITE}
                fontWeight={700}>
                {n.label}
              </text>
            </g>
          );
        })}
      </svg>

      <div style={{
        position: "absolute", top: 64, left: 80,
        fontFamily: "'Courier New', monospace", fontSize: 26,
        color: CYAN, letterSpacing: "0.4em", textTransform: "uppercase",
        opacity: fadeIn(frame, 18, 22),
        textShadow: `0 0 20px ${CYAN}66`,
      }}>
        codegraph intelligence
      </div>

      <div style={{
        position: "absolute", bottom: 64, right: 80,
        fontFamily: "'Courier New', monospace", fontSize: 22,
        color: OFFWHITE, letterSpacing: "0.15em",
        opacity: fadeIn(frame, 50, 20),
      }}>
        every symbol · every call edge · before you write a line
      </div>
    </AbsoluteFill>
  );
};

// ─── Scene 4: Swarm  (340–470) ───────────────────────────────────────────────
const AGENT_COUNT = 28;

const SwarmScene: React.FC<{ frame: number }> = ({ frame }) => {
  const W = 1920, H = 1080;
  const cx = W / 2, cy = H / 2;
  const sceneIn  = fadeIn(frame, 0, 28);
  const sceneOut = frame > 100 ? fadeOut(frame, 102, 16) : 1;

  const agents = Array.from({ length: AGENT_COUNT }).map((_, i) => {
    const angle  = (i / AGENT_COUNT) * Math.PI * 2 + 0.1;
    const ring   = i < 8 ? 210 : i < 18 ? 380 : 540;
    const delay  = Math.floor(i / 8) * 12 + (i % 8) * 4;
    const t = spring({ frame: frame - delay, fps: 30, config: { damping: 16, stiffness: 110 } });
    const x = cx + Math.cos(angle) * ring * t;
    const y = cy + Math.sin(angle) * ring * t * 0.52;
    return { x, y, t, delay, i };
  });

  const stepsOp = fadeIn(frame, 48, 24);

  return (
    <AbsoluteFill style={{ background: BG, opacity: sceneIn * sceneOut }}>
      <Scanlines color={ORANGE} opacity={0.018} />

      <svg width={W} height={H} style={{ position: "absolute", inset: 0 }}>
        {/* lines from orchestrator */}
        {agents.map(({ x, y, t, i }) => (
          <line key={i} x1={cx} y1={cy} x2={x} y2={y}
            stroke={ORANGE} strokeWidth={1} opacity={0.3 * t} />
        ))}

        {/* orchestrator rings */}
        {[90, 64, 36].map((r, i) => (
          <circle key={i} cx={cx} cy={cy}
            r={r + Math.sin(frame * 0.09 + i) * (4 - i)}
            fill="none" stroke={ORANGE} strokeWidth={i === 2 ? 2 : 0.8}
            opacity={[0.15, 0.25, 1][i]}
            style={{ filter: i === 2 ? `drop-shadow(0 0 24px ${ORANGE})` : undefined }} />
        ))}
        <circle cx={cx} cy={cy} r={36}
          fill={ORANGE}
          style={{ filter: `drop-shadow(0 0 32px ${ORANGE})` }} />
        <text x={cx} y={cy + 6} textAnchor="middle"
          fontFamily="'Courier New', monospace" fontSize={13}
          fill={BG} fontWeight={700} letterSpacing="0.05em">ORCH</text>

        {/* agents */}
        {agents.map(({ x, y, t, i }) => (
          <g key={i}>
            <circle cx={x} cy={y} r={13 * t}
              fill={`${CYAN}1e`} stroke={CYAN} strokeWidth={1.5}
              style={{ filter: `drop-shadow(0 0 8px ${CYAN})` }} />
            <text x={x} y={y + 5} textAnchor="middle"
              fontFamily="'Courier New', monospace" fontSize={9}
              fill={`${CYAN}cc`}>A{i + 1}</text>
          </g>
        ))}
      </svg>

      {/* header */}
      <div style={{
        position: "absolute", top: 64, width: "100%", textAlign: "center",
        fontFamily: "'Courier New', monospace", fontSize: 16,
        color: `${ORANGE}88`, letterSpacing: "0.35em", textTransform: "uppercase",
        opacity: fadeIn(frame, 16, 22),
      }}>
        up to 100 parallel agents · real OS threads · linear scaling
      </div>

      {/* steps */}
      <div style={{
        position: "absolute", bottom: 80, width: "100%",
        display: "flex", justifyContent: "center", alignItems: "center", gap: 0,
        opacity: stepsOp,
      }}>
        {(["spawn", "explore", "converge"] as const).map((label, i) => (
          <div key={i} style={{ display: "flex", alignItems: "center" }}>
            {i > 0 && (
              <div style={{
                width: 80, height: 1,
                background: `linear-gradient(90deg, ${ORANGE}44, ${ORANGE}99)`,
                margin: "0 4px",
              }} />
            )}
            <div style={{
              fontFamily: "'Courier New', monospace",
              fontSize: 28, letterSpacing: "0.2em",
              color: i === 1 ? ORANGE : MUTED,
              textTransform: "uppercase",
              textShadow: i === 1 ? `0 0 20px ${ORANGE}` : "none",
            }}>
              {label}
            </div>
          </div>
        ))}
      </div>
    </AbsoluteFill>
  );
};

// ─── Scene 5: Stats  (465–580) ──────────────────────────────────────────────
const STATS = [
  { value: "< 1 MB",  label: "static binary",    color: CYAN   },
  { value: "100",     label: "parallel agents",   color: ORANGE },
  { value: "top 5",   label: "hackathon finish",  color: PURPLE },
  { value: "zero",    label: "dependencies",      color: CYAN   },
];

const StatsScene: React.FC<{ frame: number }> = ({ frame }) => {
  const sceneIn  = fadeIn(frame, 0, 28);
  const sceneOut = frame > 90 ? fadeOut(frame, 92, 16) : 1;

  return (
    <AbsoluteFill style={{
      background: BG, opacity: sceneIn * sceneOut,
      display: "flex", flexDirection: "column",
      alignItems: "center", justifyContent: "center", gap: 20,
    }}>
      <Scanlines />
      <div style={{
        fontFamily: "'Courier New', monospace", fontSize: 15,
        color: MUTED, letterSpacing: "0.5em", textTransform: "uppercase",
        marginBottom: 32, opacity: fadeIn(frame, 8, 18),
      }}>
        devswarm · by the numbers
      </div>

      <div style={{ display: "flex", gap: 32 }}>
        {STATS.map(({ value, label, color }, i) => {
          const delay = i * 10;
          const t = spring({ frame: frame - delay, fps: 30, config: { damping: 14 } });
          return (
            <div key={i} style={{
              width: 320, padding: "48px 36px",
              border: `1px solid ${color}33`,
              background: `${color}07`,
              display: "flex", flexDirection: "column",
              alignItems: "center", gap: 16,
              transform: `translateY(${(1 - t) * 40}px)`,
              opacity: t,
              boxShadow: `0 0 50px ${color}18, inset 0 0 30px ${color}06`,
            }}>
              <div style={{
                fontFamily: "'Courier New', monospace",
                fontSize: 72, fontWeight: 700,
                color, lineHeight: 1,
                textShadow: `0 0 40px ${color}99`,
              }}>{value}</div>
              <div style={{
                fontFamily: "'Courier New', monospace",
                fontSize: 15, color: MUTED,
                letterSpacing: "0.25em", textTransform: "uppercase",
              }}>{label}</div>
            </div>
          );
        })}
      </div>

      <div style={{
        marginTop: 40,
        fontFamily: "'Courier New', monospace", fontSize: 16,
        color: MUTED, letterSpacing: "0.3em",
        opacity: fadeIn(frame, 45, 18),
      }}>
        written in zig · works on macos & linux · AGPL-3.0
      </div>
    </AbsoluteFill>
  );
};

// ─── Scene 6: CTA  (575–660) ─────────────────────────────────────────────────
const CTAScene: React.FC<{ frame: number }> = ({ frame }) => {
  const sceneIn = fadeIn(frame, 0, 28);
  const cmdOp   = fadeIn(frame, 22, 24);
  const linkOp  = fadeIn(frame, 40, 22);
  const tagOp   = fadeIn(frame, 55, 22);
  const cursor  = Math.floor(frame / 14) % 2 === 0;

  return (
    <AbsoluteFill style={{
      background: BG, opacity: sceneIn,
      display: "flex", flexDirection: "column",
      alignItems: "center", justifyContent: "center", gap: 36,
    }}>
      <Scanlines />
      {/* ambient glow */}
      <div style={{
        position: "absolute", width: 800, height: 600, borderRadius: "50%",
        background: `radial-gradient(ellipse, ${CYAN}0d 0%, transparent 65%)`,
      }} />

      <div style={{
        fontFamily: "'Courier New', monospace",
        fontSize: 164, fontWeight: 700, letterSpacing: "0.1em",
        color: CYAN, lineHeight: 1,
        textShadow: `0 0 80px ${CYAN}aa, 0 0 160px ${CYAN}44`,
      }}>
        devswarm
      </div>

      <div style={{
        fontFamily: "'Courier New', monospace",
        fontSize: 30, color: OFFWHITE,
        background: `${OFFWHITE}07`,
        border: `1px solid ${OFFWHITE}16`,
        padding: "20px 52px",
        letterSpacing: "0.08em",
        opacity: cmdOp,
        boxShadow: `0 0 40px ${CYAN}18`,
      }}>
        <span style={{ color: MUTED }}>$ </span>
        <span style={{ color: CYAN }}>npm install -g devswarm</span>
        <span style={{ opacity: cursor ? 1 : 0, color: CYAN }}>▌</span>
      </div>

      <div style={{
        fontFamily: "'Courier New', monospace", fontSize: 17,
        color: MUTED, letterSpacing: "0.18em",
        opacity: linkOp,
      }}>
        github.com/justrach/codedb
      </div>

      <div style={{
        display: "flex", gap: 14, opacity: tagOp,
      }}>
        {["#zig", "#mcp", "#ai", "#swarm", "#devtools", "#opensource"].map((t) => (
          <span key={t} style={{
            fontFamily: "'Courier New', monospace", fontSize: 14,
            color: MUTED, letterSpacing: "0.1em",
            border: `1px solid ${OFFWHITE}14`, padding: "6px 14px",
          }}>{t}</span>
        ))}
      </div>
    </AbsoluteFill>
  );
};

// ─── Root ─────────────────────────────────────────────────────────────────────
export const DevSwarm: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ background: BG }}>
      {/* Scene 1: codedb  0–100 */}
      {frame < 102 && <CodedbScene frame={frame} />}

      {/* Scene 2: rename  95–210 */}
      <Sequence from={93} durationInFrames={120}>
        <RenameScene frame={frame - 93} />
      </Sequence>

      {/* Scene 3: graph  205–348 */}
      <Sequence from={208} durationInFrames={142}>
        <GraphScene frame={frame - 208} />
      </Sequence>

      {/* Scene 4: swarm  342–475 */}
      <Sequence from={344} durationInFrames={132}>
        <SwarmScene frame={frame - 344} />
      </Sequence>

      {/* Scene 5: stats  468–582 */}
      <Sequence from={470} durationInFrames={114}>
        <StatsScene frame={frame - 470} />
      </Sequence>

      {/* Scene 6: CTA  575–660 */}
      <Sequence from={576} durationInFrames={84}>
        <CTAScene frame={frame - 576} />
      </Sequence>
    </AbsoluteFill>
  );
};
