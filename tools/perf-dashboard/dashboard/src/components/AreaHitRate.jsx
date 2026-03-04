import { C, Card, SectionHeader } from "./shared";

export default function AreaHitRate({ areas }) {
  return (
    <Card>
      <SectionHeader>Area Hit Rate</SectionHeader>
      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        {[...areas].sort((a, b) => b.hitRate - a.hitRate).map(area => (
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
  );
}
