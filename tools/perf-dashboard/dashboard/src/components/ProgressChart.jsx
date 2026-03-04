import { AreaChart, Area, Line, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, ReferenceLine } from "recharts";
import { C, Card, SectionHeader, CustomTooltip } from "./shared";

export default function ProgressChart({ progress }) {
  return (
    <Card>
      <SectionHeader>Performance Index Over Time</SectionHeader>
      <div style={{ height: 200 }}>
        <ResponsiveContainer width="100%" height="100%">
          <AreaChart data={progress} margin={{ top: 5, right: 10, bottom: 5, left: 10 }}>
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
        {[["Overall", C.green, "\u2501"], ["EVM", C.evm, "\u254C"], ["Trie", C.trie, "\u254C"], ["State", C.state, "\u254C"], ["RLP", C.rlp, "\u254C"]].map(([name, color, line]) => (
          <div key={name} style={{ display: "flex", alignItems: "center", gap: 5, fontSize: 10 }}>
            <span style={{ color, fontWeight: 700 }}>{line}</span>
            <span style={{ color: C.textDim }}>{name}</span>
          </div>
        ))}
      </div>
    </Card>
  );
}
