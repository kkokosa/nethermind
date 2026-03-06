import { useState } from "react";
import { useLiveData } from "../hooks/useApiData";
import { C, Card, SectionHeader } from "./shared";

const AREA_COLORS = {
  evm: C.evm, trie: C.trie, state: C.state,
  rlp: C.rlp, db: C.db, bp: C.bp,
};

const STATUS_ORDER = ["proposed", "ready", "active", "completed", "exhausted", "rejected"];

const DifficultyBadge = ({ d }) => {
  const colors = { S: C.green, M: C.amber, L: C.red };
  const color = colors[d] || C.textDim;
  return (
    <span style={{
      fontSize: 9, fontWeight: 700, padding: "1px 5px", borderRadius: 2,
      color, background: `${color}15`, border: `1px solid ${color}30`,
    }}>
      {d}
    </span>
  );
};

const ImpactBadge = ({ impact }) => {
  const colors = { high: C.green, med: C.amber, low: C.textDim };
  const color = colors[impact] || C.textDim;
  return (
    <span style={{
      fontSize: 9, fontWeight: 600, padding: "1px 5px", borderRadius: 2,
      color, background: `${color}15`,
    }}>
      {impact}
    </span>
  );
};

const TargetRow = ({ t }) => {
  const areaColor = AREA_COLORS[t.area] || C.textDim;
  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 8, padding: "5px 0",
      borderBottom: `1px solid ${C.border}`,
    }}>
      <span style={{
        fontSize: 10, fontWeight: 700, color: areaColor, minWidth: 60,
        background: `${areaColor}12`, padding: "2px 5px", borderRadius: 2,
      }}>
        {t.id}
      </span>
      <span style={{ flex: 1, fontSize: 11, color: C.text, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
        {t.title}
      </span>
      <DifficultyBadge d={t.difficulty} />
      <ImpactBadge impact={t.impact} />
      {t.source && t.source !== "seed" && (
        <span style={{ fontSize: 9, color: C.textDim }}>{t.source}</span>
      )}
      {t.confidence != null && (
        <span style={{ fontSize: 9, color: C.textDim }}>
          {(t.confidence * 100).toFixed(0)}%
        </span>
      )}
    </div>
  );
};

export default function BacklogView() {
  const backlog = useLiveData("/api/backlog", []);
  const [showCompleted, setShowCompleted] = useState(false);

  if (!backlog || backlog.length === 0) {
    return (
      <Card>
        <SectionHeader>Backlog</SectionHeader>
        <div style={{ fontSize: 11, color: C.textDim }}>
          No targets. Run: python backlog.py seed
        </div>
      </Card>
    );
  }

  const grouped = {};
  for (const status of STATUS_ORDER) {
    grouped[status] = [];
  }
  for (const t of backlog) {
    if (grouped[t.status]) {
      grouped[t.status].push(t);
    }
  }

  const counts = {};
  for (const [status, items] of Object.entries(grouped)) {
    counts[status] = items.length;
  }

  const readyCount = counts.ready || 0;
  const lowBacklog = readyCount < 3;

  return (
    <Card>
      <SectionHeader>Backlog</SectionHeader>

      {/* Summary bar */}
      <div style={{ display: "flex", gap: 10, marginBottom: 10, flexWrap: "wrap" }}>
        {STATUS_ORDER.map(s => (
          <span key={s} style={{
            fontSize: 10, color: s === "ready" ? C.green : s === "active" ? C.amber : C.textDim,
          }}>
            {counts[s] || 0} {s}
          </span>
        ))}
      </div>

      {/* Low backlog warning */}
      {lowBacklog && (
        <div style={{
          fontSize: 10, color: C.amber, padding: "4px 8px", marginBottom: 8,
          background: `${C.amber}10`, borderRadius: 3, border: `1px solid ${C.amber}30`,
        }}>
          Low backlog ({readyCount} ready) — consider running researcher
        </div>
      )}

      {/* Proposed */}
      {grouped.proposed.length > 0 && (
        <div style={{ marginBottom: 10 }}>
          <div style={{ fontSize: 10, fontWeight: 700, color: C.purple, marginBottom: 4, letterSpacing: "0.05em" }}>
            PROPOSED ({grouped.proposed.length})
          </div>
          {grouped.proposed.map(t => (
            <TargetRow key={t.id} t={t} />
          ))}
        </div>
      )}

      {/* Ready */}
      {grouped.ready.length > 0 && (
        <div style={{ marginBottom: 10 }}>
          <div style={{ fontSize: 10, fontWeight: 700, color: C.green, marginBottom: 4, letterSpacing: "0.05em" }}>
            READY ({grouped.ready.length})
          </div>
          {grouped.ready.map(t => (
            <TargetRow key={t.id} t={t} />
          ))}
        </div>
      )}

      {/* Active */}
      {grouped.active.length > 0 && (
        <div style={{ marginBottom: 10 }}>
          <div style={{ fontSize: 10, fontWeight: 700, color: C.amber, marginBottom: 4, letterSpacing: "0.05em" }}>
            ACTIVE ({grouped.active.length})
          </div>
          {grouped.active.map(t => (
            <TargetRow key={t.id} t={t} />
          ))}
        </div>
      )}

      {/* Completed/Exhausted/Rejected — collapsed */}
      {(counts.completed + counts.exhausted + counts.rejected > 0) && (
        <div>
          <div
            onClick={() => setShowCompleted(!showCompleted)}
            style={{
              fontSize: 10, color: C.textDim, cursor: "pointer",
              marginTop: 4, userSelect: "none",
            }}
          >
            {showCompleted ? "\u25BC" : "\u25B6"} Completed ({counts.completed}) / Exhausted ({counts.exhausted}) / Rejected ({counts.rejected})
          </div>
          {showCompleted && (
            <div style={{ marginTop: 4 }}>
              {[...grouped.completed, ...grouped.exhausted, ...grouped.rejected].map(t => (
                <TargetRow key={t.id} t={t} />
              ))}
            </div>
          )}
        </div>
      )}
    </Card>
  );
}
