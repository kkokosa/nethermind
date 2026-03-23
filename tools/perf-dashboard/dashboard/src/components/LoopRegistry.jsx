import { useState } from "react";
import { C, FONT, Card, SectionHeader, StatusBadge, VerdictBadge, AreaTag, Stat } from "./shared";
import LogModal from "./LogModal";

// Extract actual hypothesis from "Claimed by worker, research pending (real hypothesis)" format
function extractHypothesis(h) {
  if (!h) return "";
  const match = h.match(/\(([^)]+)\)$/);
  if (match) return match[1];
  // Fallback: remove common prefixes
  return h.replace(/^Claimed by worker,?\s*(research pending)?\s*/i, "").trim() || h;
}

export default function LoopRegistry({ loops, filteredRuns, selectedRun, onSelect, filterVerdict, setFilterVerdict, filterArea, setFilterArea }) {
  const detail = selectedRun ? loops.find(r => r.id === selectedRun) : null;
  const [showLogModal, setShowLogModal] = useState(null);

  return (
    <>
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
            <span style={{ color: C.border, margin: "0 2px" }}>|</span>
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
                {["Status", "ID", "Target", "Hypothesis", "\u0394 Mean", "\u0394 Alloc", "p-val", "Conf", "Agent", "Cost", "Date"].map(h => (
                  <th key={h} style={{ textAlign: "left", padding: "6px 8px", fontSize: 9, fontWeight: 700, letterSpacing: "0.1em", color: C.textDim, textTransform: "uppercase", whiteSpace: "nowrap" }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {filteredRuns.map(run => (
                <tr
                  key={run.id}
                  onClick={() => onSelect(selectedRun === run.id ? null : run.id)}
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
                  <td style={{ padding: "7px 8px", color: C.textDim, maxWidth: 220, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{extractHypothesis(run.hypothesis)}</td>
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
                  <td style={{ padding: "7px 8px", fontSize: 10, color: C.textDim }}>${(run.cost || 0).toFixed(2)}</td>
                  <td style={{ padding: "7px 8px", fontSize: 10, color: C.textDim, whiteSpace: "nowrap" }}>{run.date ? run.date.slice(5) : ""}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>

      {/* Detail Panel */}
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
            <button onClick={() => onSelect(null)} style={{ background: "none", border: "none", color: C.textDim, cursor: "pointer", fontSize: 16, fontFamily: FONT }}>&#x2715;</button>
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(7, auto)", gap: 20, padding: "12px 0", borderTop: `1px solid ${C.border}`, borderBottom: `1px solid ${C.border}` }}>
            <Stat small label="Branch" value={detail.branch ? detail.branch.split("/").slice(-1)[0] : "—"} />
            <Stat small label="Difficulty" value={detail.difficulty || "—"} />
            <Stat small label="Iterations" value={detail.iterations || 0} />
            <Stat small label="Tokens" value={`${((detail.tokens || 0) / 1000).toFixed(0)}k`} />
            <Stat small label="Cost" value={`$${(detail.cost || 0).toFixed(2)}`} />
            <Stat small label="p-value" value={detail.pValue !== null ? detail.pValue.toFixed(3) : "—"} color={detail.pValue !== null && detail.pValue < 0.05 ? C.green : C.textDim} />
            <Stat small label="Confidence" value={detail.confidence !== null ? `${(detail.confidence * 100).toFixed(0)}%` : "—"} color={detail.confidence > 0.8 ? C.green : C.amber} />
          </div>
          <div style={{ marginTop: 12, display: "flex", gap: 8, fontSize: 10 }}>
            <a href="#" style={{ color: C.accent, textDecoration: "none" }}>View Diff &rarr;</a>
            <span style={{ color: C.border }}>|</span>
            <a href="#" style={{ color: C.accent, textDecoration: "none" }}>BDN Results (JSON) &rarr;</a>
            <span style={{ color: C.border }}>|</span>
            <a
              href="#"
              onClick={(e) => { e.preventDefault(); setShowLogModal(detail.id); }}
              style={{ color: C.accent, textDecoration: "none" }}
            >
              Agent Reasoning Log &rarr;
            </a>
          </div>
        </Card>
      )}

      {/* Log modal */}
      {showLogModal && (
        <LogModal
          loopRunId={showLogModal}
          onClose={() => setShowLogModal(null)}
          isLive={false}
        />
      )}
    </>
  );
}
