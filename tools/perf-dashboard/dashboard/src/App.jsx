import { useState, useMemo } from "react";

import LOOP_RUNS from "./data/loops.json";
import PROGRESS_DATA from "./data/progress.json";
import BENCHMARK_TRENDS from "./data/benchmarks.json";
import agentData from "./data/agents.json";

import { C, FONT, Card, Stat } from "./components/shared";
import ProgressChart from "./components/ProgressChart";
import LoopRegistry from "./components/LoopRegistry";
import BenchmarkTrends from "./components/BenchmarkTrends";
import AgentEffectiveness from "./components/AgentEffectiveness";
import AreaHitRate from "./components/AreaHitRate";
import FailureAnalysis from "./components/FailureAnalysis";
import TargetCoverage from "./components/TargetCoverage";
import ActivityLog from "./components/ActivityLog";

const AGENT_STATS = agentData.agentStats;
const AREA_EFFECTIVENESS = agentData.areaEffectiveness;
const FAILURE_TAXONOMY = agentData.failureTaxonomy;

export default function Dashboard() {
  const [selectedRun, setSelectedRun] = useState(null);
  const [filterVerdict, setFilterVerdict] = useState("all");
  const [filterArea, setFilterArea] = useState("all");

  const totalMerged = LOOP_RUNS.filter(r => r.status === "merged").length;
  const totalDiscarded = LOOP_RUNS.filter(r => r.status === "discarded").length;
  const totalActive = LOOP_RUNS.filter(r => ["implementing", "benchmarking", "research"].includes(r.status)).length;
  const overallHitRate = ((totalMerged / (totalMerged + totalDiscarded)) * 100).toFixed(0);
  const latestPerfIndex = PROGRESS_DATA.length > 0 ? PROGRESS_DATA[PROGRESS_DATA.length - 1].perfIndex : 100;
  const totalCost = LOOP_RUNS.reduce((s, r) => s + (r.cost || 0), 0);
  const costPerImprovement = totalMerged > 0 ? (totalCost / totalMerged).toFixed(2) : "\u2014";
  const noiseFloor = PROGRESS_DATA.length > 0 ? PROGRESS_DATA[PROGRESS_DATA.length - 1].noiseFloor : 0;

  const bestWin = useMemo(() => {
    const merged = LOOP_RUNS.filter(r => r.verdict === "improvement" && r.deltaMean !== null);
    if (merged.length === 0) return { delta: 0, target: "none" };
    const best = merged.reduce((a, b) => (a.deltaMean < b.deltaMean ? a : b));
    return { delta: best.deltaMean, target: `${best.targetId} ${best.target}` };
  }, []);

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
          <span style={{ color: C.border }}>|</span>
          <span>branch: perf-ai/setup</span>
        </div>
      </div>

      {/* ── TOP KPIs ── */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(6, 1fr)", gap: 12, marginBottom: 20 }}>
        <Card>
          <Stat label="Perf Index" value={latestPerfIndex.toFixed(1)} color={C.green} />
          <div style={{ fontSize: 10, color: C.green, marginTop: 6 }}>&#x25BC; {(100 - latestPerfIndex).toFixed(1)}% from baseline</div>
        </Card>
        <Card>
          <Stat label="Loops Total" value={LOOP_RUNS.length} color={C.textBright} />
          <div style={{ fontSize: 10, color: C.textDim, marginTop: 6 }}>
            <span style={{ color: C.green }}>{totalMerged} merged</span>{" \u00B7 "}
            <span style={{ color: C.amber }}>{totalActive} active</span>{" \u00B7 "}
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
          <Stat label="Noise Floor" value={`\u00B1${noiseFloor}%`} color={C.textDim} />
          <div style={{ fontSize: 10, color: C.textDim, marginTop: 6 }}>from null runs (same-vs-same)</div>
        </Card>
        <Card>
          <Stat label="Best Win" value={`${bestWin.delta.toFixed(1)}%`} color={C.green} />
          <div style={{ fontSize: 10, color: C.textDim, marginTop: 6 }}>{bestWin.target}</div>
        </Card>
      </div>

      {/* ── MAIN GRID ── */}
      <div style={{ display: "grid", gridTemplateColumns: "1fr 380px", gap: 16 }}>
        {/* Left Column */}
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
          <ProgressChart progress={PROGRESS_DATA} />
          <LoopRegistry
            loops={LOOP_RUNS}
            filteredRuns={filteredRuns}
            selectedRun={selectedRun}
            onSelect={setSelectedRun}
            filterVerdict={filterVerdict}
            setFilterVerdict={setFilterVerdict}
            filterArea={filterArea}
            setFilterArea={setFilterArea}
          />
          <BenchmarkTrends benchmarks={BENCHMARK_TRENDS} />
        </div>

        {/* Right Column */}
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
          <AgentEffectiveness agents={AGENT_STATS} />
          <AreaHitRate areas={AREA_EFFECTIVENESS} />
          <FailureAnalysis failures={FAILURE_TAXONOMY} totalDiscarded={totalDiscarded} />
          <TargetCoverage loops={LOOP_RUNS} />
          <ActivityLog progress={PROGRESS_DATA} />
        </div>
      </div>

      {/* ── FOOTER ── */}
      <div style={{ marginTop: 20, paddingTop: 12, borderTop: `1px solid ${C.border}`, display: "flex", justifyContent: "space-between", fontSize: 10, color: C.textDim }}>
        <span>Data: SQLite + BenchmarkDotNet JSON exports &middot; Baseline: upstream master @ fork point (Jun 01)</span>
        <span>Null-run calibration: nightly &middot; Statistical test: Mann-Whitney U, &alpha;=0.05</span>
      </div>
    </div>
  );
}
