import { C, Card, SectionHeader } from "./shared";

export default function ActivityLog({ progress }) {
  const events = progress.filter(d => d.event).reverse().slice(0, 8);

  return (
    <Card>
      <SectionHeader>Activity Log</SectionHeader>
      <div style={{ display: "flex", flexDirection: "column", gap: 0 }}>
        {events.map((d, i) => {
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
  );
}
