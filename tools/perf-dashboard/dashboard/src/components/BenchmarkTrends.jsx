import { C, Card, SectionHeader, MiniChart } from "./shared";

export default function BenchmarkTrends({ benchmarks }) {
  return (
    <Card>
      <SectionHeader count={benchmarks.length}>Key Benchmark Trends</SectionHeader>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(2, 1fr)", gap: 12 }}>
        {benchmarks.map(bench => {
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
                  {first.toLocaleString()} &rarr; {last.toLocaleString()} ns
                </div>
              </div>
            </div>
          );
        })}
      </div>
    </Card>
  );
}
