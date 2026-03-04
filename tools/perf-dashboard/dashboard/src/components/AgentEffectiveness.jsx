import { C, Card, SectionHeader } from "./shared";

export default function AgentEffectiveness({ agents }) {
  return (
    <Card>
      <SectionHeader>Agent Effectiveness</SectionHeader>
      {agents.map(agent => (
        <div key={agent.agent} style={{ marginBottom: 14, paddingBottom: 14, borderBottom: `1px solid ${C.border}` }}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
            <span style={{ fontSize: 12, fontWeight: 700, color: C.textBright }}>{agent.agent}</span>
            <span style={{ fontSize: 11, color: agent.hitRate >= 50 ? C.green : C.amber, fontWeight: 700 }}>{agent.hitRate}% hit rate</span>
          </div>
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
  );
}
