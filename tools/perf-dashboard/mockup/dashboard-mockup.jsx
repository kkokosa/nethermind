import { useState, useMemo } from "react";
import { LineChart, Line, AreaChart, Area, BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, ReferenceLine, Cell } from "recharts";

// ─── MOCK DATA ────────────────────────────────────────────────────────────────

const LOOP_RUNS = [
  { id: "LR-001", targetId: "EVM-1", target: "PopAddress .ToArray()", hypothesis: "Remove .ToArray() from PopAddress — Address already accepts ReadOnlySpan<byte>", status: "merged", verdict: "improvement", deltaMean: -19.0, deltaAlloc: -100, confidence: 0.98, agent: "claude-code", cost: 0.42, tokens: 38400, date: "2025-06-02", branch: "perf/evm-1/remove-popaddress-toarray", difficulty: "S", impact: "High", pValue: 0.001, iterations: 2 },
  { id: "LR-002", targetId: "STATE-1", target: "LINQ in storage flush", hypothesis: "Replace Where→OrderByDescending→Select LINQ chain with manual loop + in-place sort", status: "merged", verdict: "improvement", deltaMean: -8.3, deltaAlloc: -45, confidence: 0.91, agent: "claude-code", cost: 0.61, tokens: 55200, date: "2025-06-05", branch: "perf/state-1/replace-linq-storage-flush", difficulty: "S", impact: "Med", pValue: 0.008, iterations: 1 },
  { id: "LR-003", targetId: "TRIE-5", target: "Interlocked in DirtyNodesCache", hypothesis: "Batch 4 Interlocked operations into 2 by combining count+memory updates", status: "merged", verdict: "improvement", deltaMean: -3.2, deltaAlloc: 0, confidence: 0.72, agent: "claude-code", cost: 0.38, tokens: 34100, date: "2025-06-08", branch: "perf/trie-5/batch-interlocked", difficulty: "S", impact: "Med", pValue: 0.042, iterations: 3 },
  { id: "LR-004", targetId: "DB-1", target: "Interlocked per DB read", hypothesis: "Replace Interlocked.Increment with [ThreadStatic] counters aggregated on timer", status: "discarded", verdict: "neutral", deltaMean: -0.8, deltaAlloc: 0, confidence: 0.31, agent: "claude-code", cost: 0.89, tokens: 81200, date: "2025-06-10", branch: "perf/db-1/threadstatic-counters", difficulty: "S", impact: "Med", pValue: 0.340, iterations: 4 },
  { id: "LR-005", targetId: "EVM-2", target: "SSTORE .ToArray() per write", hypothesis: "Change IWorldState.Set() to accept ReadOnlySpan<byte>, eliminating 32B alloc per SSTORE", status: "merged", verdict: "improvement", deltaMean: -12.7, deltaAlloc: -100, confidence: 0.95, agent: "claude-code", cost: 1.23, tokens: 112000, date: "2025-06-14", branch: "perf/evm-2/sstore-span", difficulty: "M", impact: "High", pValue: 0.003, iterations: 5 },
  { id: "LR-006", targetId: "TRIE-1", target: "Inline node .ToArray()", hypothesis: "Add TrieNode constructor accepting ReadOnlySpan<byte> for inline node resolution", status: "merged", verdict: "improvement", deltaMean: -15.4, deltaAlloc: -88, confidence: 0.96, agent: "claude-code", cost: 0.97, tokens: 88500, date: "2025-06-18", branch: "perf/trie-1/inline-node-span", difficulty: "M", impact: "High", pValue: 0.002, iterations: 3 },
  { id: "LR-007", targetId: "BP-1", target: "Bloom parallel threshold", hypothesis: "Add serial fallback for blocks with <16 receipts to avoid parallel infrastructure overhead", status: "merged", verdict: "improvement", deltaMean: -22.1, deltaAlloc: -67, confidence: 0.94, agent: "gemini-code", cost: 0.15, tokens: 52000, date: "2025-06-20", branch: "perf/bp-1/bloom-serial-fallback", difficulty: "S", impact: "Low", pValue: 0.004, iterations: 1 },
  { id: "LR-008", targetId: "EVM-3", target: "RETURN data .ToArray()", hypothesis: "Change ReturnData from byte[] to ReadOnlyMemory<byte> to avoid copy on call frame return", status: "implementing", verdict: null, deltaMean: null, deltaAlloc: null, confidence: null, agent: "claude-code", cost: 0.44, tokens: 40100, date: "2025-06-22", branch: "perf/evm-3/return-data-memory", difficulty: "M", impact: "High", pValue: null, iterations: 2 },
  { id: "LR-009", targetId: "RLP-1", target: "Rlp.Encode(long) alloc", hypothesis: "Cache Rlp instances for values 0-1024 and use stackalloc for larger values", status: "discarded", verdict: "regression", deltaMean: 4.2, deltaAlloc: -30, confidence: 0.85, agent: "claude-code", cost: 0.71, tokens: 64800, date: "2025-06-12", branch: "perf/rlp-1/encode-long-cache", difficulty: "M", impact: "Med", pValue: 0.015, iterations: 3 },
  { id: "LR-010", targetId: "STATE-4", target: "Storage root parallel threshold", hypothesis: "Use sum of EstimatedChanges > 500 instead of contract count > 3 for parallel decision", status: "benchmarking", verdict: null, deltaMean: null, deltaAlloc: null, confidence: null, agent: "gemini-code", cost: 0.22, tokens: 20100, date: "2025-06-23", branch: "perf/state-4/work-based-threshold", difficulty: "S", impact: "Med", pValue: null, iterations: 1 },
  { id: "LR-011", targetId: "TRIE-4", target: "HexPrefix nibble allocs", hypothesis: "Expand static cache from length≤3 to length≤8, covering 95% of branch creation paths", status: "discarded", verdict: "neutral", deltaMean: -1.1, deltaAlloc: -12, confidence: 0.28, agent: "claude-code", cost: 0.33, tokens: 30200, date: "2025-06-16", branch: "perf/trie-4/expand-nibble-cache", difficulty: "S", impact: "Med", pValue: 0.410, iterations: 2 },
];

const PROGRESS_DATA = [
  { date: "Jun 01", perfIndex: 100, evmIndex: 100, trieIndex: 100, stateIndex: 100, rlpIndex: 100, noiseFloor: 2.1 },
  { date: "Jun 02", perfIndex: 96.2, evmIndex: 93.8, trieIndex: 100, stateIndex: 100, rlpIndex: 100, noiseFloor: 2.0, event: "EVM-1 merged" },
  { date: "Jun 05", perfIndex: 94.8, evmIndex: 93.8, trieIndex: 100, stateIndex: 96.5, rlpIndex: 100, noiseFloor: 2.2, event: "STATE-1 merged" },
  { date: "Jun 08", perfIndex: 93.9, evmIndex: 93.8, trieIndex: 98.2, stateIndex: 96.5, rlpIndex: 100, noiseFloor: 1.9, event: "TRIE-5 merged" },
  { date: "Jun 10", perfIndex: 93.9, evmIndex: 93.8, trieIndex: 98.2, stateIndex: 96.5, rlpIndex: 100, noiseFloor: 2.3, event: "DB-1 discarded" },
  { date: "Jun 12", perfIndex: 93.9, evmIndex: 93.8, trieIndex: 98.2, stateIndex: 96.5, rlpIndex: 100, noiseFloor: 2.1, event: "RLP-1 regression" },
  { date: "Jun 14", perfIndex: 91.1, evmIndex: 87.4, trieIndex: 98.2, stateIndex: 96.5, rlpIndex: 100, noiseFloor: 2.0, event: "EVM-2 merged" },
  { date: "Jun 16", perfIndex: 91.1, evmIndex: 87.4, trieIndex: 98.2, stateIndex: 96.5, rlpIndex: 100, noiseFloor: 2.4, event: "TRIE-4 neutral" },
  { date: "Jun 18", perfIndex: 88.4, evmIndex: 87.4, trieIndex: 90.1, stateIndex: 96.5, rlpIndex: 100, noiseFloor: 2.1, event: "TRIE-1 merged" },
  { date: "Jun 20", perfIndex: 87.6, evmIndex: 87.4, trieIndex: 90.1, stateIndex: 96.5, rlpIndex: 100, noiseFloor: 2.0, event: "BP-1 merged" },
  { date: "Jun 22", perfIndex: 87.6, evmIndex: 87.4, trieIndex: 90.1, stateIndex: 96.5, rlpIndex: 100, noiseFloor: 2.2 },
  { date: "Jun 23", perfIndex: 87.6, evmIndex: 87.4, trieIndex: 90.1, stateIndex: 96.5, rlpIndex: 100, noiseFloor: 1.8 },
];

const AGENT_STATS = [
  { agent: "claude-code", loops: 9, improvements: 5, regressions: 1, neutral: 2, inProgress: 1, hitRate: 55.6, avgCost: 0.66, totalCost: 5.98, avgTokens: 60500 },
  { agent: "gemini-code", loops: 2, improvements: 1, regressions: 0, neutral: 0, inProgress: 1, hitRate: 50.0, avgCost: 0.19, totalCost: 0.37, avgTokens: 36050 },
];

const FAILURE_TAXONOMY = [
  { reason: "Below noise floor", count: 2, pct: 28.6 },
  { reason: "Regression detected", count: 1, pct: 14.3 },
  { reason: "Build/test failure", count: 0, pct: 0 },
  { reason: "Agent gave up", count: 0, pct: 0 },
];

const AREA_EFFECTIVENESS = [
  { area: "EVM", attempted: 4, improved: 3, hitRate: 75, avgDelta: -15.9 },
  { area: "Trie", attempted: 3, improved: 2, hitRate: 67, avgDelta: -9.3 },
  { area: "State", attempted: 2, improved: 1, hitRate: 50, avgDelta: -8.3 },
  { area: "RLP", attempted: 1, improved: 0, hitRate: 0, avgDelta: 4.2 },
  { area: "DB", attempted: 1, improved: 0, hitRate: 0, avgDelta: -0.8 },
  { area: "Block Proc", attempted: 1, improved: 1, hitRate: 100, avgDelta: -22.1 },
];

const BENCHMARK_TRENDS = [
  { name: "BlockProcessing.Transfers_200", data: [
    { date: "Jun 01", ns: 4850 }, { date: "Jun 05", ns: 4720 }, { date: "Jun 08", ns: 4680 },
    { date: "Jun 14", ns: 4320 }, { date: "Jun 18", ns: 4010 }, { date: "Jun 20", ns: 3890 }, { date: "Jun 23", ns: 3890 },
  ]},
  { name: "EvmOpcodes.SSTORE", data: [
    { date: "Jun 01", ns: 1240 }, { date: "Jun 05", ns: 1240 }, { date: "Jun 08", ns: 1240 },
    { date: "Jun 14", ns: 1082 }, { date: "Jun 18", ns: 1082 }, { date: "Jun 20", ns: 1082 }, { date: "Jun 23", ns: 1082 },
  ]},
  { name: "EvmOpcodes.CALL", data: [
    { date: "Jun 01", ns: 890 }, { date: "Jun 02", ns: 720 }, { date: "Jun 08", ns: 720 },
    { date: "Jun 14", ns: 720 }, { date: "Jun 18", ns: 720 }, { date: "Jun 20", ns: 720 }, { date: "Jun 23", ns: 720 },
  ]},
  { name: "PatriciaTree.Commit_4096", data: [
    { date: "Jun 01", ns: 28500 }, { date: "Jun 05", ns: 28500 }, { date: "Jun 08", ns: 27600 },
    { date: "Jun 14", ns: 27600 }, { date: "Jun 18", ns: 24100 }, { date: "Jun 20", ns: 24100 }, { date: "Jun 23", ns: 24100 },
  ]},
];

// ─── THEME ────────────────────────────────────────────────────────────────────

const C = {
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

const FONT = "'JetBrains Mono', 'Fira Code', 'SF Mono', 'Cascadia Code', monospace";

// ─── COMPONENTS ───────────────────────────────────────────────────────────────

const StatusBadge = ({ status }) => {
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

const VerdictBadge = ({ verdict, delta }) => {
  if (!verdict) return <span style={{ color: C.textDim, fontSize: 11 }}>—</span>;
  const isGood = verdict === "improvement";
  const isBad = verdict === "regression";
  const color = isGood ? C.green : isBad ? C.red : C.textDim;
  return (
    <span style={{ color, fontSize: 12, fontWeight: 600, fontFamily: FONT }}>
      {delta !== null ? `${delta > 0 ? "+" : ""}${delta.toFixed(1)}%` : verdict}
    </span>
  );
};

const AreaTag = ({ area }) => {
  const colorMap = { EVM: C.evm, Trie: C.trie, State: C.state, RLP: C.rlp, DB: C.db, "Block Proc": C.bp };
  const areaKey = area.split("-")[0].replace(/\d+/g, "").trim();
  const matched = Object.entries(colorMap).find(([k]) => area.toUpperCase().startsWith(k.toUpperCase()));
  const color = matched ? matched[1] : C.textDim;
  return (
    <span style={{ fontSize: 10, fontWeight: 600, letterSpacing: "0.05em", padding: "1px 6px", borderRadius: 2, color, background: `${color}15`, fontFamily: FONT }}>
      {area}
    </span>
  );
};

const Stat = ({ label, value, unit, color, small }) => (
  <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
    <span style={{ fontSize: 10, color: C.textDim, letterSpacing: "0.08em", fontWeight: 600, textTransform: "uppercase" }}>{label}</span>
    <div style={{ display: "flex", alignItems: "baseline", gap: 3 }}>
      <span style={{ fontSize: small ? 18 : 26, fontWeight: 700, color: color || C.textBright, fontFamily: FONT, lineHeight: 1 }}>{value}</span>
      {unit && <span style={{ fontSize: 11, color: C.textDim }}>{unit}</span>}
    </div>
  </div>
);

const SectionHeader = ({ children, count }) => (
  <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 12 }}>
    <h2 style={{ fontSize: 11, fontWeight: 700, letterSpacing: "0.12em", textTransform: "uppercase", color: C.textDim, margin: 0 }}>{children}</h2>
    {count !== undefined && (
      <span style={{ fontSize: 10, color: C.accent, background: `${C.accent}15`, padding: "1px 6px", borderRadius: 3, fontWeight: 700, fontFamily: FONT }}>{count}</span>
    )}
    <div style={{ flex: 1, height: 1, background: C.border }} />
  </div>
);

const Card = ({ children, style }) => (
  <div style={{ background: C.bgCard, border: `1px solid ${C.border}`, borderRadius: 6, padding: 16, ...style }}>
    {children}
  </div>
);

const MiniChart = ({ data, dataKey, color, height = 40, showDots = false }) => (
  <ResponsiveContainer width="100%" height={height}>
    <AreaChart data={data} margin={{ top: 2, right: 2, bottom: 2, left: 2 }}>
      <defs>
        <linearGradient id={`grad-${color.replace("#", "")}`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={color} stopOpacity={0.25} />
          <stop offset="100%" stopColor={color} stopOpacity={0} />
        </linearGradient>
      </defs>
      <Area type="stepAfter" dataKey={dataKey} stroke={color} strokeWidth={1.5} fill={`url(#grad-${color.replace("#", "")})`} dot={showDots ? { r: 2, fill: color } : false} />
    </AreaChart>
  </ResponsiveContainer>
);

const CustomTooltip = ({ active, payload, label }) => {
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

// ─── MAIN DASHBOARD ───────────────────────────────────────────────────────────

export default function Dashboard() {
  const [selectedRun, setSelectedRun] = useState(null);
  const [filterVerdict, setFilterVerdict] = useState("all");
  const [filterArea, setFilterArea] = useState("all");

  const totalMerged = LOOP_RUNS.filter(r => r.status === "merged").length;
  const totalDiscarded = LOOP_RUNS.filter(r => r.status === "discarded").length;
  const totalActive = LOOP_RUNS.filter(r => ["implementing", "benchmarking", "research"].includes(r.status)).length;
  const overallHitRate = ((totalMerged / (totalMerged + totalDiscarded)) * 100).toFixed(0);
  const latestPerfIndex = PROGRESS_DATA[PROGRESS_DATA.length - 1].perfIndex;
  const totalCost = LOOP_RUNS.reduce((s, r) => s + r.cost, 0);
  const costPerImprovement = totalMerged > 0 ? (totalCost / totalMerged).toFixed(2) : "—";

  const filteredRuns = useMemo(() => {
    return LOOP_RUNS.filter(r => {
      if (filterVerdict !== "all") {
        if (filterVerdict === "active") return ["implementing", "benchmarking", "research"].includes(r.status);
        if (filterVerdict === "improvement") return r.verdict === "improvement";
        if (filterVerdict === "failed") return r.verdict === "regression" || r.verdict === "neutral";
      }
      return true;
    }).filter(r => {
      if (filterArea !== "all") return r.targetId.toLowerCase().startsWith(filterArea.toLowerCase());
      return true;
    });
  }, [filterVerdict, filterArea]);

  const detail = selectedRun ? LOOP_RUNS.find(r => r.id === selectedRun) : null;

  return (
    <div style={{ fontFamily: FONT, background: C.bg, color: C.text, minHeight: "100vh", padding: "16px 20px", boxSizing: "border-box" }}>
      {/* ── HEADER ── */}
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 20, paddingBottom: 14, borderBottom: `1px solid ${C.border}` }}>
        <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
          <div style={{ width: 8, height: 8, borderRadius: "50%", background: C.green, boxShadow: `0 0 8px ${C.green}60` }} />
          <h1 style={{ fontSize: 15, fontWeight: 700, color: C.textBright, margin: 0, letterSpacing: "-0.01em" }}>nethermind<span style={{ color: C.accent }}>/</span>perf-ai</h1>
          <span style={{ fontSize: 11, color: C.textDim, marginLeft: 4 }}>AI Performance Loop Dashboard</span>
        </div>
        <div style={{ display: "flex", gap: 12, alignItems: "center", fontSize: 10, color: C.textDim }}>
          <span>fork: kkokosa/nethermind</span>
          <span style={{ color: C.border }}>│</span>
          <span>branch: perf-ai/setup</span>
          <span style={{ color: C.border }}>│</span>
          <span>updated 2m ago</span>
        </div>
      </div>

      {/* ── TOP KPIs ── */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(6, 1fr)", gap: 12, marginBottom: 20 }}>
        <Card>
          <Stat label="Perf Index" value={latestPerfIndex.toFixed(1)} color={C.green} />
          <div style={{ fontSize: 10, color: C.green, marginTop: 6 }}>▼ {(100 - latestPerfIndex).toFixed(1)}% from baseline</div>
        </Card>
        <Card>
          <Stat label="Loops Total" value={LOOP_RUNS.length} color={C.textBright} />
          <div style={{ fontSize: 10, color: C.textDim, marginTop: 6 }}>
            <span style={{ color: C.green }}>{totalMerged} merged</span>{" · "}
            <span style={{ color: C.amber }}>{totalActive} active</span>{" · "}
            <span>{totalDiscarded} disc</span>
          </div>
        </Card>
        <Card>
          <Stat label="Hit Rate" value={`${overallHitRate}%`} color={parseInt(overallHitRate) > 50 ? C.green : C.amber} />
          <div style={{ fontSize: 10, color: C.textDim, marginTop: 6 }}>{totalMerged} of {totalMerged + totalDiscarded} completed</div>
        </Card>
        <Card>
          <Stat label="Cost / Improvement" value={`$${costPerImprovement}`} color={C.textBright} />
          <div style={{ fontSize: 10, color: C.textDim, marginTop: 6 }}>total: ${totalCost.toFixed(2)}</div>
        </Card>
        <Card>
          <Stat label="Noise Floor" value={`±${PROGRESS_DATA[PROGRESS_DATA.length - 1].noiseFloor}%`} color={C.textDim} />
          <div style={{ fontSize: 10, color: C.textDim, marginTop: 6 }}>from null runs (same-vs-same)</div>
        </Card>
        <Card>
          <Stat label="Best Win" value="-22.1%" color={C.green} />
          <div style={{ fontSize: 10, color: C.textDim, marginTop: 6 }}>BP-1 bloom serial fallback</div>
        </Card>
      </div>

      {/* ── MAIN GRID: 2 columns ── */}
      <div style={{ display: "grid", gridTemplateColumns: "1fr 380px", gap: 16 }}>

        {/* ── LEFT COLUMN ── */}
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>

          {/* ── PROGRESS CHART ── */}
          <Card>
            <SectionHeader>Performance Index Over Time</SectionHeader>
            <div style={{ height: 200 }}>
              <ResponsiveContainer width="100%" height="100%">
                <AreaChart data={PROGRESS_DATA} margin={{ top: 5, right: 10, bottom: 5, left: 10 }}>
                  <defs>
                    <linearGradient id="gradPerf" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="0%" stopColor={C.green} stopOpacity={0.15} />
                      <stop offset="100%" stopColor={C.green} stopOpacity={0} />
                    </linearGradient>
                  </defs>
                  <CartesianGrid stroke={C.border} strokeDasharray="3 3" vertical={false} />
                  <XAxis dataKey="date" tick={{ fontSize: 10, fill: C.textDim }} axisLine={{ stroke: C.border }} tickLine={false} />
                  <YAxis domain={[82, 102]} tick={{ fontSize: 10, fill: C.textDim }} axisLine={false} tickLine={false} width={32} />
                  <Tooltip content={<CustomTooltip />} />
                  <ReferenceLine y={100} stroke={C.textDim} strokeDasharray="3 3" strokeWidth={1} />
                  <Area type="stepAfter" dataKey="perfIndex" name="Overall" stroke={C.green} strokeWidth={2} fill="url(#gradPerf)" dot={{ r: 3, fill: C.green, stroke: C.bg, strokeWidth: 2 }} />
                  <Line type="stepAfter" dataKey="evmIndex" name="EVM" stroke={C.evm} strokeWidth={1} dot={false} strokeDasharray="4 2" />
                  <Line type="stepAfter" dataKey="trieIndex" name="Trie" stroke={C.trie} strokeWidth={1} dot={false} strokeDasharray="4 2" />
                  <Line type="stepAfter" dataKey="stateIndex" name="State" stroke={C.state} strokeWidth={1} dot={false} strokeDasharray="4 2" />
                </AreaChart>
              </ResponsiveContainer>
            </div>
            <div style={{ display: "flex", gap: 16, marginTop: 8, paddingLeft: 10 }}>
              {[["Overall", C.green, "━"], ["EVM", C.evm, "╌"], ["Trie", C.trie, "╌"], ["State", C.state, "╌"], ["RLP", C.rlp, "╌"]].map(([name, color, line]) => (
                <div key={name} style={{ display: "flex", alignItems: "center", gap: 5, fontSize: 10 }}>
                  <span style={{ color, fontWeight: 700 }}>{line}</span>
                  <span style={{ color: C.textDim }}>{name}</span>
                </div>
              ))}
            </div>
          </Card>

          {/* ── LOOP REGISTRY ── */}
          <Card style={{ flex: 1 }}>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 12 }}>
              <SectionHeader count={filteredRuns.length}>Loop Registry</SectionHeader>
              <div style={{ display: "flex", gap: 6 }}>
                {["all", "improvement", "active", "failed"].map(f => (
                  <button
                    key={f}
                    onClick={() => setFilterVerdict(f)}
                    style={{
                      fontSize: 10, fontFamily: FONT, fontWeight: 600, letterSpacing: "0.05em",
                      padding: "3px 8px", borderRadius: 3, border: `1px solid ${filterVerdict === f ? C.accent : C.border}`,
                      background: filterVerdict === f ? `${C.accent}15` : "transparent",
                      color: filterVerdict === f ? C.accent : C.textDim, cursor: "pointer",
                      textTransform: "uppercase",
                    }}
                  >
                    {f}
                  </button>
                ))}
                <span style={{ color: C.border, margin: "0 2px" }}>│</span>
                {["all", "evm", "trie", "state", "rlp", "db", "bp"].map(f => (
                  <button
                    key={f}
                    onClick={() => setFilterArea(f)}
                    style={{
                      fontSize: 10, fontFamily: FONT, fontWeight: 600, letterSpacing: "0.05em",
                      padding: "3px 8px", borderRadius: 3, border: `1px solid ${filterArea === f ? C.accent : C.border}`,
                      background: filterArea === f ? `${C.accent}15` : "transparent",
                      color: filterArea === f ? C.accent : C.textDim, cursor: "pointer",
                      textTransform: "uppercase",
                    }}
                  >
                    {f}
                  </button>
                ))}
              </div>
            </div>

            <div style={{ overflowX: "auto" }}>
              <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 11 }}>
                <thead>
                  <tr style={{ borderBottom: `1px solid ${C.border}` }}>
                    {["Status", "ID", "Target", "Hypothesis", "Δ Mean", "Δ Alloc", "p-val", "Conf", "Agent", "Cost", "Date"].map(h => (
                      <th key={h} style={{ textAlign: "left", padding: "6px 8px", fontSize: 9, fontWeight: 700, letterSpacing: "0.1em", color: C.textDim, textTransform: "uppercase", whiteSpace: "nowrap" }}>{h}</th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {filteredRuns.map(run => (
                    <tr
                      key={run.id}
                      onClick={() => setSelectedRun(selectedRun === run.id ? null : run.id)}
                      style={{
                        borderBottom: `1px solid ${C.border}`,
                        cursor: "pointer",
                        background: selectedRun === run.id ? C.bgCardHover : "transparent",
                        transition: "background 0.15s",
                      }}
                      onMouseEnter={e => { if (selectedRun !== run.id) e.currentTarget.style.background = `${C.bgCardHover}80`; }}
                      onMouseLeave={e => { if (selectedRun !== run.id) e.currentTarget.style.background = "transparent"; }}
                    >
                      <td style={{ padding: "7px 8px" }}><StatusBadge status={run.status} /></td>
                      <td style={{ padding: "7px 8px", fontWeight: 600, color: C.accent, whiteSpace: "nowrap" }}>{run.targetId}</td>
                      <td style={{ padding: "7px 8px", whiteSpace: "nowrap", maxWidth: 140, overflow: "hidden", textOverflow: "ellipsis" }}>{run.target}</td>
                      <td style={{ padding: "7px 8px", color: C.textDim, maxWidth: 220, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{run.hypothesis}</td>
                      <td style={{ padding: "7px 8px" }}><VerdictBadge verdict={run.verdict} delta={run.deltaMean} /></td>
                      <td style={{ padding: "7px 8px" }}><VerdictBadge verdict={run.verdict} delta={run.deltaAlloc} /></td>
                      <td style={{ padding: "7px 8px", color: run.pValue !== null && run.pValue < 0.05 ? C.green : C.textDim, fontSize: 11 }}>
                        {run.pValue !== null ? run.pValue.toFixed(3) : "—"}
                      </td>
                      <td style={{ padding: "7px 8px" }}>
                        {run.confidence !== null ? (
                          <div style={{ display: "flex", alignItems: "center", gap: 4 }}>
                            <div style={{ width: 30, height: 4, background: C.border, borderRadius: 2, overflow: "hidden" }}>
                              <div style={{ width: `${run.confidence * 100}%`, height: "100%", background: run.confidence > 0.8 ? C.green : run.confidence > 0.5 ? C.amber : C.red, borderRadius: 2 }} />
                            </div>
                            <span style={{ fontSize: 10, color: C.textDim }}>{(run.confidence * 100).toFixed(0)}</span>
                          </div>
                        ) : "—"}
                      </td>
                      <td style={{ padding: "7px 8px", fontSize: 10, color: C.textDim }}>{run.agent.split("-")[0]}</td>
                      <td style={{ padding: "7px 8px", fontSize: 10, color: C.textDim }}>${run.cost.toFixed(2)}</td>
                      <td style={{ padding: "7px 8px", fontSize: 10, color: C.textDim, whiteSpace: "nowrap" }}>{run.date.slice(5)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Card>

          {/* ── DETAIL PANEL ── */}
          {detail && (
            <Card style={{ borderColor: C.accent + "40" }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 12 }}>
                <div>
                  <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 4 }}>
                    <StatusBadge status={detail.status} />
                    <AreaTag area={detail.targetId} />
                    <span style={{ fontSize: 13, fontWeight: 700, color: C.textBright }}>{detail.target}</span>
                  </div>
                  <div style={{ fontSize: 11, color: C.textDim, maxWidth: 700 }}>{detail.hypothesis}</div>
                </div>
                <button onClick={() => setSelectedRun(null)} style={{ background: "none", border: "none", color: C.textDim, cursor: "pointer", fontSize: 16, fontFamily: FONT }}>✕</button>
              </div>
              <div style={{ display: "grid", gridTemplateColumns: "repeat(7, auto)", gap: 20, padding: "12px 0", borderTop: `1px solid ${C.border}`, borderBottom: `1px solid ${C.border}` }}>
                <Stat small label="Branch" value={detail.branch.split("/").slice(-1)[0]} />
                <Stat small label="Difficulty" value={detail.difficulty} />
                <Stat small label="Iterations" value={detail.iterations} />
                <Stat small label="Tokens" value={`${(detail.tokens / 1000).toFixed(0)}k`} />
                <Stat small label="Cost" value={`$${detail.cost.toFixed(2)}`} />
                <Stat small label="p-value" value={detail.pValue !== null ? detail.pValue.toFixed(3) : "—"} color={detail.pValue !== null && detail.pValue < 0.05 ? C.green : C.textDim} />
                <Stat small label="Confidence" value={detail.confidence !== null ? `${(detail.confidence * 100).toFixed(0)}%` : "—"} color={detail.confidence > 0.8 ? C.green : C.amber} />
              </div>
              <div style={{ marginTop: 12, display: "flex", gap: 8, fontSize: 10 }}>
                <a href="#" style={{ color: C.accent, textDecoration: "none" }}>View Diff →</a>
                <span style={{ color: C.border }}>│</span>
                <a href="#" style={{ color: C.accent, textDecoration: "none" }}>BDN Results (JSON) →</a>
                <span style={{ color: C.border }}>│</span>
                <a href="#" style={{ color: C.accent, textDecoration: "none" }}>Agent Reasoning Log →</a>
                <span style={{ color: C.border }}>│</span>
                <a href="#" style={{ color: C.accent, textDecoration: "none" }}>GitHub Issue →</a>
              </div>
            </Card>
          )}

          {/* ── BENCHMARK TRENDS ── */}
          <Card>
            <SectionHeader count={BENCHMARK_TRENDS.length}>Key Benchmark Trends</SectionHeader>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(2, 1fr)", gap: 12 }}>
              {BENCHMARK_TRENDS.map(bench => {
                const first = bench.data[0].ns;
                const last = bench.data[bench.data.length - 1].ns;
                const delta = ((last - first) / first * 100).toFixed(1);
                return (
                  <div key={bench.name} style={{ background: C.bg, borderRadius: 4, padding: "10px 12px", border: `1px solid ${C.border}` }}>
                    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 6 }}>
                      <span style={{ fontSize: 10, color: C.textDim, fontWeight: 600 }}>{bench.name}</span>
                      <span style={{ fontSize: 11, fontWeight: 700, color: parseFloat(delta) <= 0 ? C.green : C.red }}>{delta}%</span>
                    </div>
                    <div style={{ display: "flex", alignItems: "flex-end", gap: 8 }}>
                      <div style={{ flex: 1 }}>
                        <MiniChart data={bench.data} dataKey="ns" color={parseFloat(delta) <= 0 ? C.green : C.red} height={36} />
                      </div>
                      <div style={{ fontSize: 10, color: C.textDim, whiteSpace: "nowrap", paddingBottom: 2 }}>
                        {first.toLocaleString()} → {last.toLocaleString()} ns
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          </Card>
        </div>

        {/* ── RIGHT COLUMN ── */}
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>

          {/* ── AGENT EFFECTIVENESS ── */}
          <Card>
            <SectionHeader>Agent Effectiveness</SectionHeader>
            {AGENT_STATS.map(agent => (
              <div key={agent.agent} style={{ marginBottom: 14, paddingBottom: 14, borderBottom: `1px solid ${C.border}` }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
                  <span style={{ fontSize: 12, fontWeight: 700, color: C.textBright }}>{agent.agent}</span>
                  <span style={{ fontSize: 11, color: agent.hitRate >= 50 ? C.green : C.amber, fontWeight: 700 }}>{agent.hitRate}% hit rate</span>
                </div>
                {/* Stacked bar */}
                <div style={{ display: "flex", height: 8, borderRadius: 4, overflow: "hidden", marginBottom: 8, background: C.bg }}>
                  <div style={{ width: `${(agent.improvements / agent.loops) * 100}%`, background: C.green, transition: "width 0.3s" }} />
                  <div style={{ width: `${(agent.inProgress / agent.loops) * 100}%`, background: C.amber, transition: "width 0.3s" }} />
                  <div style={{ width: `${(agent.neutral / agent.loops) * 100}%`, background: C.textDim, transition: "width 0.3s" }} />
                  <div style={{ width: `${(agent.regressions / agent.loops) * 100}%`, background: C.red, transition: "width 0.3s" }} />
                </div>
                <div style={{ display: "grid", gridTemplateColumns: "repeat(2, 1fr)", gap: 4, fontSize: 10 }}>
                  <div style={{ display: "flex", justifyContent: "space-between", color: C.textDim }}>
                    <span>Loops</span><span style={{ color: C.text }}>{agent.loops}</span>
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between", color: C.textDim }}>
                    <span>Total cost</span><span style={{ color: C.text }}>${agent.totalCost.toFixed(2)}</span>
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between", color: C.textDim }}>
                    <span>Avg tokens</span><span style={{ color: C.text }}>{(agent.avgTokens / 1000).toFixed(0)}k</span>
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between", color: C.textDim }}>
                    <span>$/improvement</span><span style={{ color: C.text }}>${(agent.totalCost / (agent.improvements || 1)).toFixed(2)}</span>
                  </div>
                </div>
              </div>
            ))}
            <div style={{ display: "flex", gap: 12, fontSize: 10 }}>
              {[["Improved", C.green], ["Active", C.amber], ["Neutral", C.textDim], ["Regressed", C.red]].map(([label, color]) => (
                <div key={label} style={{ display: "flex", alignItems: "center", gap: 4 }}>
                  <div style={{ width: 8, height: 8, borderRadius: 2, background: color }} />
                  <span style={{ color: C.textDim }}>{label}</span>
                </div>
              ))}
            </div>
          </Card>

          {/* ── AREA HEATMAP ── */}
          <Card>
            <SectionHeader>Area Hit Rate</SectionHeader>
            <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
              {AREA_EFFECTIVENESS.sort((a, b) => b.hitRate - a.hitRate).map(area => (
                <div key={area.area} style={{ display: "flex", alignItems: "center", gap: 10 }}>
                  <span style={{ fontSize: 10, fontWeight: 700, width: 65, color: C.textDim }}>{area.area}</span>
                  <div style={{ flex: 1, height: 16, background: C.bg, borderRadius: 3, overflow: "hidden", position: "relative" }}>
                    <div style={{
                      width: `${area.hitRate}%`, height: "100%", borderRadius: 3,
                      background: area.hitRate >= 70 ? C.green : area.hitRate >= 40 ? C.amber : C.red,
                      opacity: 0.7, transition: "width 0.5s",
                    }} />
                    <span style={{ position: "absolute", right: 6, top: "50%", transform: "translateY(-50%)", fontSize: 9, fontWeight: 700, color: C.textBright }}>
                      {area.hitRate}% ({area.improved}/{area.attempted})
                    </span>
                  </div>
                  <span style={{ fontSize: 10, color: area.avgDelta <= 0 ? C.green : C.red, fontWeight: 600, width: 50, textAlign: "right" }}>
                    {area.avgDelta > 0 ? "+" : ""}{area.avgDelta.toFixed(1)}%
                  </span>
                </div>
              ))}
            </div>
          </Card>

          {/* ── FAILURE TAXONOMY ── */}
          <Card>
            <SectionHeader count={totalDiscarded}>Failure Analysis</SectionHeader>
            <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
              {FAILURE_TAXONOMY.map(f => (
                <div key={f.reason} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", fontSize: 11 }}>
                  <span style={{ color: C.textDim }}>{f.reason}</span>
                  <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                    <div style={{ width: 60, height: 4, background: C.bg, borderRadius: 2, overflow: "hidden" }}>
                      <div style={{ width: `${f.pct}%`, height: "100%", background: f.count > 0 ? C.amber : C.border, borderRadius: 2 }} />
                    </div>
                    <span style={{ fontWeight: 600, color: C.text, width: 16, textAlign: "right" }}>{f.count}</span>
                  </div>
                </div>
              ))}
            </div>
          </Card>

          {/* ── OPTIMIZATION TARGET COVERAGE ── */}
          <Card>
            <SectionHeader>Target Coverage</SectionHeader>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(6, 1fr)", gap: 3 }}>
              {["EVM-1","EVM-2","EVM-3","EVM-4","TRIE-1","TRIE-2","TRIE-3","TRIE-4","TRIE-5","STATE-1","STATE-2","STATE-3","STATE-4","RLP-1","RLP-2","DB-1","BP-1"].map(id => {
                const run = LOOP_RUNS.find(r => r.targetId === id);
                const color = !run ? C.border : run.status === "merged" ? C.green : run.status === "discarded" ? (run.verdict === "regression" ? C.red : C.textDim) : C.amber;
                return (
                  <div
                    key={id}
                    title={`${id}: ${run ? run.target : "not started"}`}
                    style={{
                      background: `${color}20`, border: `1px solid ${color}40`, borderRadius: 3,
                      padding: "4px 2px", textAlign: "center", fontSize: 8, fontWeight: 700,
                      color, letterSpacing: "0.05em", cursor: "default",
                    }}
                  >
                    {id}
                  </div>
                );
              })}
            </div>
            <div style={{ display: "flex", gap: 12, fontSize: 9, marginTop: 8, color: C.textDim }}>
              {[["Merged", C.green], ["Active", C.amber], ["Failed", C.textDim], ["Regressed", C.red], ["Not started", C.border]].map(([label, color]) => (
                <div key={label} style={{ display: "flex", alignItems: "center", gap: 3 }}>
                  <div style={{ width: 6, height: 6, borderRadius: 1, background: `${color}40`, border: `1px solid ${color}60` }} />
                  <span>{label}</span>
                </div>
              ))}
            </div>
          </Card>

          {/* ── RECENT ACTIVITY ── */}
          <Card>
            <SectionHeader>Activity Log</SectionHeader>
            <div style={{ display: "flex", flexDirection: "column", gap: 0 }}>
              {PROGRESS_DATA.filter(d => d.event).reverse().slice(0, 8).map((d, i) => {
                const isGood = d.event.includes("merged");
                const isBad = d.event.includes("regression");
                const color = isGood ? C.green : isBad ? C.red : C.textDim;
                return (
                  <div key={i} style={{ display: "flex", alignItems: "center", gap: 8, padding: "5px 0", borderBottom: `1px solid ${C.border}20` }}>
                    <div style={{ width: 5, height: 5, borderRadius: "50%", background: color, flexShrink: 0 }} />
                    <span style={{ fontSize: 10, color: C.textDim, width: 42, flexShrink: 0 }}>{d.date}</span>
                    <span style={{ fontSize: 10, color: C.text, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{d.event}</span>
                    <span style={{ fontSize: 10, color, fontWeight: 600, marginLeft: "auto", flexShrink: 0 }}>{d.perfIndex.toFixed(1)}</span>
                  </div>
                );
              })}
            </div>
          </Card>
        </div>
      </div>

      {/* ── FOOTER ── */}
      <div style={{ marginTop: 20, paddingTop: 12, borderTop: `1px solid ${C.border}`, display: "flex", justifyContent: "space-between", fontSize: 10, color: C.textDim }}>
        <span>Data: SQLite + BenchmarkDotNet JSON exports · Baseline: upstream master @ fork point (Jun 01)</span>
        <span>Null-run calibration: nightly · Statistical test: Mann-Whitney U, α=0.05</span>
      </div>
    </div>
  );
}
