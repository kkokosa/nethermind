import { AreaChart, Area, ResponsiveContainer } from "recharts";

// ─── THEME ────────────────────────────────────────────────────────────────────

export const C = {
  bg: "#0c0e13", bgCard: "#13161d", bgCardHover: "#181c25", border: "#1e2330", borderLight: "#2a3040",
  text: "#c8cdd8", textDim: "#6b7280", textBright: "#eef0f5",
  green: "#22c55e", greenDim: "#166534", greenBg: "rgba(34,197,94,0.08)",
  red: "#ef4444", redDim: "#991b1b", redBg: "rgba(239,68,68,0.08)",
  amber: "#f59e0b", amberDim: "#92400e", amberBg: "rgba(245,158,11,0.08)",
  blue: "#3b82f6", blueDim: "#1e40af", blueBg: "rgba(59,130,246,0.08)",
  cyan: "#06b6d4", purple: "#a855f7", purpleDim: "#6b21a8",
  trie: "#f97316", state: "#a855f7", rlp: "#ec4899", evm: "#3b82f6", bp: "#06b6d4", db: "#6366f1",
  accent: "#3b82f6",
};

export const FONT = "'JetBrains Mono', 'Fira Code', 'SF Mono', 'Cascadia Code', monospace";

// ─── SHARED COMPONENTS ────────────────────────────────────────────────────────

export const StatusBadge = ({ status }) => {
  const map = {
    merged: { color: C.green, bg: C.greenBg, label: "MERGED" },
    implementing: { color: C.blue, bg: C.blueBg, label: "IMPL" },
    benchmarking: { color: C.amber, bg: C.amberBg, label: "BENCH" },
    discarded: { color: C.textDim, bg: "rgba(107,114,128,0.1)", label: "DISCARD" },
    research: { color: C.purple, bg: "rgba(168,85,247,0.08)", label: "RESEARCH" },
  };
  const s = map[status] || map.discarded;
  return (
    <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: "0.08em", padding: "2px 7px", borderRadius: 3, color: s.color, background: s.bg, border: `1px solid ${s.color}22`, fontFamily: FONT }}>
      {s.label}
    </span>
  );
};

export const VerdictBadge = ({ verdict, delta }) => {
  if (!verdict) return <span style={{ color: C.textDim, fontSize: 11 }}>—</span>;
  const isGood = verdict === "improvement";
  const isBad = verdict === "regression";
  const color = isGood ? C.green : isBad ? C.red : C.textDim;
  return (
    <span style={{ color, fontSize: 12, fontWeight: 600, fontFamily: FONT }}>
      {delta !== null && delta !== undefined ? `${delta > 0 ? "+" : ""}${delta.toFixed(1)}%` : verdict}
    </span>
  );
};

export const AreaTag = ({ area }) => {
  const colorMap = { EVM: C.evm, Trie: C.trie, State: C.state, RLP: C.rlp, DB: C.db, "Block Proc": C.bp };
  const matched = Object.entries(colorMap).find(([k]) => area.toUpperCase().startsWith(k.toUpperCase()));
  const color = matched ? matched[1] : C.textDim;
  return (
    <span style={{ fontSize: 10, fontWeight: 600, letterSpacing: "0.05em", padding: "1px 6px", borderRadius: 2, color, background: `${color}15`, fontFamily: FONT }}>
      {area}
    </span>
  );
};

export const Stat = ({ label, value, unit, color, small }) => (
  <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
    <span style={{ fontSize: 10, color: C.textDim, letterSpacing: "0.08em", fontWeight: 600, textTransform: "uppercase" }}>{label}</span>
    <div style={{ display: "flex", alignItems: "baseline", gap: 3 }}>
      <span style={{ fontSize: small ? 18 : 26, fontWeight: 700, color: color || C.textBright, fontFamily: FONT, lineHeight: 1 }}>{value}</span>
      {unit && <span style={{ fontSize: 11, color: C.textDim }}>{unit}</span>}
    </div>
  </div>
);

export const SectionHeader = ({ children, count }) => (
  <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 12 }}>
    <h2 style={{ fontSize: 11, fontWeight: 700, letterSpacing: "0.12em", textTransform: "uppercase", color: C.textDim, margin: 0 }}>{children}</h2>
    {count !== undefined && (
      <span style={{ fontSize: 10, color: C.accent, background: `${C.accent}15`, padding: "1px 6px", borderRadius: 3, fontWeight: 700, fontFamily: FONT }}>{count}</span>
    )}
    <div style={{ flex: 1, height: 1, background: C.border }} />
  </div>
);

export const Card = ({ children, style }) => (
  <div style={{ background: C.bgCard, border: `1px solid ${C.border}`, borderRadius: 6, padding: 16, ...style }}>
    {children}
  </div>
);

export const MiniChart = ({ data, dataKey, color, height = 40 }) => (
  <ResponsiveContainer width="100%" height={height}>
    <AreaChart data={data} margin={{ top: 2, right: 2, bottom: 2, left: 2 }}>
      <defs>
        <linearGradient id={`grad-${color.replace("#", "")}`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={color} stopOpacity={0.25} />
          <stop offset="100%" stopColor={color} stopOpacity={0} />
        </linearGradient>
      </defs>
      <Area type="stepAfter" dataKey={dataKey} stroke={color} strokeWidth={1.5} fill={`url(#grad-${color.replace("#", "")})`} dot={false} />
    </AreaChart>
  </ResponsiveContainer>
);

export const CustomTooltip = ({ active, payload, label }) => {
  if (!active || !payload?.length) return null;
  return (
    <div style={{ background: "#1a1e28", border: `1px solid ${C.borderLight}`, borderRadius: 4, padding: "6px 10px", fontSize: 11, fontFamily: FONT }}>
      <div style={{ color: C.textDim, marginBottom: 3 }}>{label}</div>
      {payload.map((p, i) => (
        <div key={i} style={{ color: p.color, display: "flex", gap: 8, justifyContent: "space-between" }}>
          <span>{p.name}</span>
          <span style={{ fontWeight: 700 }}>{typeof p.value === "number" ? p.value.toFixed(1) : p.value}</span>
        </div>
      ))}
    </div>
  );
};
