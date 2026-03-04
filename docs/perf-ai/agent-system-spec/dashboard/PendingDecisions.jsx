import { useState, useEffect, useCallback } from 'react';

const DECISION_API = '/api/pending';
const SUBMIT_API = '/api/decision';
const STATUS_API = '/api/status';
const POLL_INTERVAL = 5000;

// ── Styling constants (matches existing dashboard theme) ────────────────────

const colors = {
  bg: '#0c0e13',
  surface: '#141720',
  surfaceHover: '#1a1f2e',
  border: '#1e2433',
  borderActive: '#2a3a5c',
  text: '#c8cdd8',
  textDim: '#6b7280',
  textBright: '#e5e7eb',
  green: '#22c55e',
  greenDim: '#166534',
  red: '#ef4444',
  redDim: '#7f1d1d',
  amber: '#f59e0b',
  blue: '#3b82f6',
  purple: '#a855f7',
  accent: '#38bdf8',
};

const mono = "'JetBrains Mono', 'Fira Code', monospace";

// ── Subcomponents ───────────────────────────────────────────────────────────

function ComparisonTable({ comparisons }) {
  if (!comparisons || comparisons.length === 0) return null;

  return (
    <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '12px', fontFamily: mono }}>
      <thead>
        <tr style={{ borderBottom: `1px solid ${colors.border}` }}>
          {['Benchmark', 'Baseline', 'Candidate', '\u0394 Mean', '\u0394 Alloc', 'p-value'].map(h => (
            <th key={h} style={{ padding: '6px 8px', textAlign: 'left', color: colors.textDim, fontWeight: 500 }}>{h}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {comparisons.map((c, i) => {
          const deltaMean = c.delta_mean_pct;
          const deltaAlloc = c.delta_alloc_pct;
          const isImprovement = deltaMean < -2;
          const isRegression = deltaMean > 2;

          return (
            <tr key={i} style={{ borderBottom: `1px solid ${colors.border}08` }}>
              <td style={{ padding: '5px 8px', color: colors.text, maxWidth: 280, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {c.full_name?.split('.').pop() || c.full_name}
              </td>
              <td style={{ padding: '5px 8px', color: colors.textDim }}>
                {c.baseline_mean_ns ? `${(c.baseline_mean_ns).toFixed(1)} ns` : '-'}
              </td>
              <td style={{ padding: '5px 8px', color: colors.textDim }}>
                {c.candidate_mean_ns ? `${(c.candidate_mean_ns).toFixed(1)} ns` : '-'}
              </td>
              <td style={{
                padding: '5px 8px', fontWeight: 600,
                color: isImprovement ? colors.green : isRegression ? colors.red : colors.textDim
              }}>
                {deltaMean != null ? `${deltaMean > 0 ? '+' : ''}${deltaMean.toFixed(1)}%` : '-'}
                {isImprovement && ' \u2713'}
                {isRegression && ' \u2717'}
              </td>
              <td style={{
                padding: '5px 8px',
                color: (deltaAlloc != null && deltaAlloc < -10) ? colors.green : colors.textDim
              }}>
                {deltaAlloc != null ? `${deltaAlloc > 0 ? '+' : ''}${deltaAlloc.toFixed(0)}%` : '-'}
              </td>
              <td style={{ padding: '5px 8px', color: colors.textDim }}>
                {c.p_value != null ? c.p_value.toFixed(4) : '-'}
              </td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

function MarkdownBlock({ content, label }) {
  const [expanded, setExpanded] = useState(false);
  if (!content) return null;

  const preview = content.split('\n').slice(0, 4).join('\n');

  return (
    <div style={{ marginTop: 8 }}>
      <button
        onClick={() => setExpanded(!expanded)}
        style={{
          background: 'none', border: 'none', color: colors.accent,
          cursor: 'pointer', fontSize: '11px', fontFamily: mono, padding: 0,
        }}
      >
        {expanded ? '\u25BC' : '\u25B6'} {label}
      </button>
      {expanded && (
        <pre style={{
          marginTop: 4, padding: 10, background: colors.bg,
          borderRadius: 4, border: `1px solid ${colors.border}`,
          fontSize: '11px', lineHeight: 1.5, color: colors.text,
          whiteSpace: 'pre-wrap', wordBreak: 'break-word',
          maxHeight: 400, overflow: 'auto', fontFamily: mono,
        }}>
          {content}
        </pre>
      )}
    </div>
  );
}

function LiveWorkerBar({ workers }) {
  if (!workers || workers.length === 0) return null;

  return (
    <div style={{
      marginBottom: 16, padding: '10px 14px',
      background: colors.surface, border: `1px solid ${colors.border}`,
      borderRadius: 6,
    }}>
      <div style={{ fontSize: '11px', color: colors.textDim, marginBottom: 6, fontFamily: mono }}>
        LIVE AGENTS ({workers.length})
      </div>
      {workers.map((w, i) => (
        <div key={i} style={{
          display: 'flex', alignItems: 'center', gap: 8,
          padding: '4px 0', borderBottom: i < workers.length - 1 ? `1px solid ${colors.border}08` : 'none',
        }}>
          <span style={{
            width: 6, height: 6, borderRadius: '50%',
            background: colors.green, display: 'inline-block',
            animation: 'pulse 2s infinite',
          }} />
          <span style={{ color: colors.accent, fontSize: '12px', fontFamily: mono, minWidth: 60 }}>
            {w.id}
          </span>
          <span style={{ color: colors.text, fontSize: '12px', fontFamily: mono, minWidth: 60 }}>
            {w.targetId}
          </span>
          <span style={{ color: colors.textDim, fontSize: '11px', fontFamily: mono, flex: 1 }}>
            {w.currentAction || w.status}
          </span>
          <span style={{ color: colors.textDim, fontSize: '10px', fontFamily: mono }}>
            attempt {w.attempt}/{w.maxAttempts}
          </span>
        </div>
      ))}
    </div>
  );
}

// ── Decision Card ───────────────────────────────────────────────────────────

function DecisionCard({ run, onDecision }) {
  const [expanded, setExpanded] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [notes, setNotes] = useState('');
  const [autoMerge, setAutoMerge] = useState(false);

  const handleDecision = async (verdict) => {
    setSubmitting(true);
    try {
      await onDecision(run.id, verdict, notes, verdict === 'improvement' ? autoMerge : false);
    } finally {
      setSubmitting(false);
    }
  };

  const bestDelta = run.best_delta_pct;
  const hasRegressions = (run.regressions || 0) > 0;

  return (
    <div style={{
      background: colors.surface,
      border: `1px solid ${expanded ? colors.borderActive : colors.border}`,
      borderRadius: 6,
      marginBottom: 8,
      transition: 'border-color 0.2s',
    }}>
      {/* Header (always visible) */}
      <div
        onClick={() => setExpanded(!expanded)}
        style={{
          padding: '12px 16px', cursor: 'pointer',
          display: 'flex', alignItems: 'center', gap: 12,
        }}
      >
        <span style={{ color: colors.accent, fontSize: '13px', fontFamily: mono, fontWeight: 600, minWidth: 60 }}>
          {run.id}
        </span>
        <span style={{
          fontSize: '11px', fontFamily: mono, padding: '2px 6px',
          background: colors.bg, borderRadius: 3, color: colors.purple,
        }}>
          {run.target_id}
        </span>
        <span style={{ color: colors.text, fontSize: '13px', flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {run.hypothesis?.split('\n')[0]?.replace(/^#+ /, '') || 'Optimization'}
        </span>
        <span style={{
          fontSize: '13px', fontFamily: mono, fontWeight: 700,
          color: bestDelta < -5 ? colors.green : bestDelta < 0 ? colors.amber : colors.red,
        }}>
          {bestDelta != null ? `${bestDelta.toFixed(1)}%` : '?'}
        </span>
        {hasRegressions && (
          <span style={{
            fontSize: '10px', fontFamily: mono, padding: '2px 6px',
            background: colors.redDim, borderRadius: 3, color: colors.red,
          }}>
            {run.regressions} regression{run.regressions > 1 ? 's' : ''}
          </span>
        )}
        <span style={{ color: colors.textDim, fontSize: '18px' }}>
          {expanded ? '\u25B4' : '\u25BE'}
        </span>
      </div>

      {/* Expanded detail */}
      {expanded && (
        <div style={{ padding: '0 16px 16px', borderTop: `1px solid ${colors.border}` }}>
          {/* Comparison table */}
          <div style={{ marginTop: 12 }}>
            <div style={{ fontSize: '11px', color: colors.textDim, marginBottom: 4, fontFamily: mono }}>
              BENCHMARK RESULTS ({run.compared_benchmarks} benchmarks)
            </div>
            <ComparisonTable comparisons={run.comparisons} />
          </div>

          {/* Expandable text blocks */}
          <MarkdownBlock content={run.hypothesis} label="Hypothesis" />
          <MarkdownBlock content={run.research_brief} label="Research Brief" />
          <MarkdownBlock content={run.measurement_report} label="Measurement Report" />

          {/* Diff stats */}
          {run.diff_stat && (
            <div style={{ marginTop: 8 }}>
              <div style={{ fontSize: '11px', color: colors.textDim, fontFamily: mono }}>DIFF</div>
              <pre style={{
                fontSize: '11px', color: colors.text, fontFamily: mono,
                marginTop: 4, padding: 8, background: colors.bg,
                borderRadius: 4, border: `1px solid ${colors.border}`,
              }}>
                {run.diff_stat}
              </pre>
            </div>
          )}

          {/* Meta info */}
          <div style={{
            marginTop: 12, display: 'flex', gap: 16, fontSize: '11px',
            fontFamily: mono, color: colors.textDim,
          }}>
            <span>branch: {run.branch}</span>
            <span>agent: {run.agent_type}</span>
            <span>cost: ${(run.cost_usd || 0).toFixed(2)}</span>
          </div>

          {/* Notes input */}
          <textarea
            placeholder="Optional notes..."
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            style={{
              width: '100%', marginTop: 12, padding: 8,
              background: colors.bg, border: `1px solid ${colors.border}`,
              borderRadius: 4, color: colors.text, fontFamily: mono,
              fontSize: '12px', resize: 'vertical', minHeight: 40,
              outline: 'none',
            }}
          />

          {/* Action buttons */}
          <div style={{ marginTop: 12, display: 'flex', alignItems: 'center', gap: 12 }}>
            {/* Auto-merge toggle */}
            <label
              style={{
                display: 'flex', alignItems: 'center', gap: 6,
                cursor: 'pointer', userSelect: 'none',
                fontSize: '11px', fontFamily: mono, color: colors.textDim,
                minWidth: 'fit-content',
              }}
              title="When checked, the branch will be squash-merged immediately after PR creation. Otherwise, only a PR is created for manual merge."
            >
              <input
                type="checkbox"
                checked={autoMerge}
                onChange={(e) => setAutoMerge(e.target.checked)}
                style={{ accentColor: colors.green, cursor: 'pointer' }}
              />
              merge immediately
            </label>

            <button
              onClick={() => handleDecision('improvement')}
              disabled={submitting}
              style={{
                flex: 1, padding: '10px 16px', fontFamily: mono,
                fontSize: '13px', fontWeight: 700, cursor: 'pointer',
                background: submitting ? colors.greenDim : colors.green,
                color: '#fff', border: 'none', borderRadius: 4,
                opacity: submitting ? 0.6 : 1,
              }}
            >
              {submitting ? 'Submitting...' : autoMerge ? '\u2713 APPROVE & MERGE' : '\u2713 APPROVE (PR only)'}
            </button>
            <button
              onClick={() => handleDecision('neutral')}
              disabled={submitting}
              style={{
                flex: 1, padding: '10px 16px', fontFamily: mono,
                fontSize: '13px', fontWeight: 700, cursor: 'pointer',
                background: submitting ? colors.redDim : 'transparent',
                color: colors.red, border: `1px solid ${colors.red}`,
                borderRadius: 4, opacity: submitting ? 0.6 : 1,
              }}
            >
              {submitting ? 'Submitting...' : '\u2717 DISCARD'}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

// ── Main Component ──────────────────────────────────────────────────────────

export default function PendingDecisions() {
  const [pending, setPending] = useState([]);
  const [workers, setWorkers] = useState([]);
  const [error, setError] = useState(null);

  const fetchData = useCallback(async () => {
    try {
      const [pendingRes, statusRes] = await Promise.all([
        fetch(DECISION_API),
        fetch(STATUS_API),
      ]);
      if (pendingRes.ok) setPending(await pendingRes.json());
      if (statusRes.ok) setWorkers(await statusRes.json());
      setError(null);
    } catch (e) {
      setError('Cannot reach decision server. Is it running?');
    }
  }, []);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, POLL_INTERVAL);
    return () => clearInterval(interval);
  }, [fetchData]);

  const handleDecision = async (loopRunId, verdict, notes, autoMerge = false) => {
    try {
      const res = await fetch(SUBMIT_API, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ loopRunId, verdict, notes, autoMerge }),
      });
      const data = await res.json();
      if (data.ok) {
        // Remove from pending list immediately
        setPending(prev => prev.filter(r => r.id !== loopRunId));
        // Show merge result if relevant
        if (data.merged === true) {
          // Successfully merged — no alert needed, it's the happy path
        } else if (data.merged === false && data.merge_error) {
          alert(`PR created but auto-merge failed: ${data.merge_error}\nMerge manually at: ${data.pr_url || 'GitHub'}`);
        }
      } else {
        alert(`Error: ${data.error}`);
      }
    } catch (e) {
      alert(`Failed to submit decision: ${e.message}`);
    }
  };

  const hasPending = pending.length > 0;
  const hasWorkers = workers.length > 0;

  if (!hasPending && !hasWorkers && !error) return null;

  return (
    <div style={{ marginBottom: 24 }}>
      {/* Live worker status */}
      <LiveWorkerBar workers={workers} />

      {/* Error state */}
      {error && (
        <div style={{
          padding: '10px 14px', marginBottom: 12,
          background: colors.redDim, border: `1px solid ${colors.red}40`,
          borderRadius: 6, fontSize: '12px', color: colors.red, fontFamily: mono,
        }}>
          {error}
        </div>
      )}

      {/* Pending decisions */}
      {hasPending && (
        <>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 8, marginBottom: 12,
          }}>
            <span style={{
              fontSize: '11px', fontFamily: mono, fontWeight: 700,
              color: colors.amber, letterSpacing: '0.05em',
            }}>
              \u2605 PENDING DECISIONS
            </span>
            <span style={{
              fontSize: '11px', fontFamily: mono, padding: '2px 8px',
              background: colors.amber + '20', borderRadius: 10,
              color: colors.amber, fontWeight: 600,
            }}>
              {pending.length}
            </span>
          </div>

          {pending.map(run => (
            <DecisionCard key={run.id} run={run} onDecision={handleDecision} />
          ))}
        </>
      )}

      <style>{`
        @keyframes pulse {
          0%, 100% { opacity: 1; }
          50% { opacity: 0.4; }
        }
      `}</style>
    </div>
  );
}
