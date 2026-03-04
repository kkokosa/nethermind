import { C, Card, SectionHeader } from "./shared";

export default function FailureAnalysis({ failures, totalDiscarded }) {
  return (
    <Card>
      <SectionHeader count={totalDiscarded}>Failure Analysis</SectionHeader>
      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        {failures.map(f => (
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
  );
}
