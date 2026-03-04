import { useState, useEffect, useRef, useCallback } from "react";
import { C, FONT } from "./shared";

const POLL_MS = 2000;

export default function LogViewer({ loopRunId, onClose }) {
  const [data, setData] = useState(null);
  const [activePhase, setActivePhase] = useState(null);
  const [autoScroll, setAutoScroll] = useState(true);
  const preRef = useRef(null);
  const userScrolledRef = useRef(false);

  const fetchLogs = useCallback(async () => {
    try {
      const res = await fetch(`/api/logs?id=${encodeURIComponent(loopRunId)}&lines=500`);
      if (res.ok) {
        const json = await res.json();
        setData(json);
        // Auto-select first phase if none selected
        if (!activePhase && json.phases?.length > 0) {
          setActivePhase(json.phases[0].name);
        }
      }
    } catch {
      // silent — will retry on next poll
    }
  }, [loopRunId, activePhase]);

  useEffect(() => {
    fetchLogs();
    const interval = setInterval(fetchLogs, POLL_MS);
    return () => clearInterval(interval);
  }, [fetchLogs]);

  // Auto-scroll when new content arrives
  useEffect(() => {
    if (autoScroll && preRef.current) {
      preRef.current.scrollTop = preRef.current.scrollHeight;
    }
  }, [data, activePhase, autoScroll]);

  const handleScroll = () => {
    if (!preRef.current) return;
    const el = preRef.current;
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
    if (!atBottom) {
      userScrolledRef.current = true;
      setAutoScroll(false);
    } else {
      userScrolledRef.current = false;
      setAutoScroll(true);
    }
  };

  const handlePhaseClick = (name) => {
    setActivePhase(name);
    setAutoScroll(true);
    userScrolledRef.current = false;
  };

  const phase = data?.phases?.find(p => p.name === activePhase);
  const lines = phase?.lines || [];
  const fileSize = phase?.size || 0;

  return (
    <div
      onClick={onClose}
      style={{
        position: "fixed", inset: 0, zIndex: 9999,
        background: "rgba(0,0,0,0.7)", backdropFilter: "blur(4px)",
        display: "flex", alignItems: "center", justifyContent: "center",
      }}
    >
      <div
        onClick={e => e.stopPropagation()}
        style={{
          width: "min(900px, 90vw)", height: "min(700px, 85vh)",
          background: C.bgCard, border: `1px solid ${C.border}`, borderRadius: 8,
          display: "flex", flexDirection: "column", overflow: "hidden",
        }}
      >
        {/* Header */}
        <div style={{
          padding: "12px 16px", borderBottom: `1px solid ${C.border}`,
          display: "flex", alignItems: "center", gap: 12,
        }}>
          <span style={{ fontSize: 13, fontWeight: 700, color: C.accent, fontFamily: FONT }}>
            {loopRunId}
          </span>

          {/* Phase tabs */}
          <div style={{ display: "flex", gap: 4, flex: 1 }}>
            {(data?.phases || []).map(p => (
              <button
                key={p.name}
                onClick={() => handlePhaseClick(p.name)}
                style={{
                  fontSize: 10, fontFamily: FONT, fontWeight: 600,
                  padding: "3px 8px", borderRadius: 3, cursor: "pointer",
                  border: `1px solid ${activePhase === p.name ? C.accent : C.border}`,
                  background: activePhase === p.name ? `${C.accent}15` : "transparent",
                  color: activePhase === p.name ? C.accent : C.textDim,
                  textTransform: "uppercase", letterSpacing: "0.05em",
                }}
              >
                {p.name}
              </button>
            ))}
          </div>

          <button
            onClick={onClose}
            style={{
              background: "none", border: "none", color: C.textDim,
              cursor: "pointer", fontSize: 18, fontFamily: FONT, padding: "0 4px",
            }}
          >
            &#x2715;
          </button>
        </div>

        {/* Body */}
        <pre
          ref={preRef}
          onScroll={handleScroll}
          style={{
            flex: 1, margin: 0, padding: 16, overflow: "auto",
            background: C.bg, fontSize: 11, lineHeight: 1.6,
            color: C.text, fontFamily: FONT, whiteSpace: "pre-wrap",
            wordBreak: "break-word",
          }}
        >
          {lines.length > 0
            ? lines.join("\n")
            : data
              ? "No log content yet."
              : "Loading..."}
        </pre>

        {/* Footer */}
        <div style={{
          padding: "8px 16px", borderTop: `1px solid ${C.border}`,
          display: "flex", alignItems: "center", justifyContent: "space-between",
          fontSize: 10, fontFamily: FONT, color: C.textDim,
        }}>
          <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
            <span>{lines.length} lines</span>
            <span>{fileSize > 1024 ? `${(fileSize / 1024).toFixed(1)} KB` : `${fileSize} B`}</span>
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
            <span style={{
              width: 6, height: 6, borderRadius: "50%",
              background: C.green, display: "inline-block",
              animation: "pulse 2s infinite",
            }} />
            <span>live</span>
            {!autoScroll && (
              <button
                onClick={() => { setAutoScroll(true); }}
                style={{
                  marginLeft: 8, fontSize: 10, fontFamily: FONT,
                  padding: "2px 6px", borderRadius: 3, cursor: "pointer",
                  background: `${C.accent}15`, border: `1px solid ${C.accent}`,
                  color: C.accent,
                }}
              >
                scroll to bottom
              </button>
            )}
          </div>
        </div>
      </div>

      <style>{`
        @keyframes pulse {
          0%, 100% { opacity: 1; }
          50% { opacity: 0.4; }
        }
      `}</style>
    </div>
  );
}
