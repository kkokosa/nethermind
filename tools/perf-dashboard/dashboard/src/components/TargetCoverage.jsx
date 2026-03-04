import { C, Card, SectionHeader } from "./shared";

const ALL_TARGETS = ["EVM-1","EVM-2","EVM-3","EVM-4","TRIE-1","TRIE-2","TRIE-3","TRIE-4","TRIE-5","STATE-1","STATE-2","STATE-3","STATE-4","RLP-1","RLP-2","DB-1","BP-1"];

export default function TargetCoverage({ loops }) {
  return (
    <Card>
      <SectionHeader>Target Coverage</SectionHeader>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(6, 1fr)", gap: 3 }}>
        {ALL_TARGETS.map(id => {
          const run = loops.find(r => r.targetId === id);
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
  );
}
