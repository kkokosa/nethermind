import { useState, useEffect, useRef, useCallback } from 'react';
import { C, FONT } from './shared';

const REFRESH_INTERVAL = 2000;

// Parse JSONL log content into formatted entries
function parseLogContent(content) {
  if (!content) return [];

  return content.split('\n').filter(line => line.trim()).map((line, idx) => {
    try {
      const obj = JSON.parse(line);
      return { idx, type: 'json', data: obj };
    } catch {
      return { idx, type: 'text', data: line };
    }
  });
}

// Format a single log entry for display
function LogEntry({ entry }) {
  const { type, data } = entry;

  if (type === 'text') {
    return <div style={{ color: C.textDim, fontFamily: FONT }}>{data}</div>;
  }

  const etype = data.type || '';

  // System init
  if (etype === 'system' && data.subtype === 'init') {
    return (
      <div style={{ color: C.textDim, padding: '4px 0' }}>
        <span style={{ color: C.accent }}>[init]</span> model={data.model}
      </div>
    );
  }

  // Assistant message
  if (etype === 'assistant') {
    const content = data.message?.content || [];
    return (
      <div style={{ padding: '4px 0' }}>
        {content.map((block, i) => {
          if (block.type === 'text') {
            return <div key={i} style={{ color: C.text, whiteSpace: 'pre-wrap' }}>{block.text}</div>;
          }
          if (block.type === 'thinking') {
            const preview = (block.thinking || '').slice(0, 150);
            return (
              <div key={i} style={{ color: C.textDim, fontStyle: 'italic' }}>
                [thinking] {preview}{block.thinking?.length > 150 ? '...' : ''}
              </div>
            );
          }
          if (block.type === 'tool_use') {
            const name = block.name || '?';
            const input = block.input || {};
            let summary = '';
            if (name === 'Read') summary = input.file_path || '';
            else if (name === 'Bash') summary = (input.command || '').slice(0, 80);
            else if (name === 'Glob') summary = input.pattern || '';
            else if (name === 'Grep') summary = `/${input.pattern}/ in ${input.path || '.'}`;
            else if (name === 'Edit') summary = input.file_path || '';
            else if (name === 'Write') summary = input.file_path || '';
            else summary = JSON.stringify(input).slice(0, 80);

            return (
              <div key={i} style={{ color: C.accent, padding: '2px 0' }}>
                &gt;&gt;&gt; {name} <span style={{ color: C.textDim }}>{summary}</span>
              </div>
            );
          }
          return null;
        })}
      </div>
    );
  }

  // Tool result
  if (etype === 'tool_result') {
    const content = typeof data.content === 'string'
      ? data.content
      : JSON.stringify(data.content);
    const preview = content.slice(0, 200);
    return (
      <div style={{ color: '#22c55e', padding: '2px 0', fontSize: '11px' }}>
        &lt;&lt;&lt; {preview}{content.length > 200 ? '...' : ''}
      </div>
    );
  }

  // Final result
  if (etype === 'result') {
    const duration = ((data.duration_ms || 0) / 1000).toFixed(1);
    const cost = (data.total_cost_usd || 0).toFixed(4);
    return (
      <div style={{ color: C.textDim, padding: '8px 0', borderTop: `1px solid ${C.border}` }}>
        --- {data.stop_reason} | {data.num_turns} turns | {duration}s | ${cost} ---
      </div>
    );
  }

  // Skip rate_limit_event and user events
  if (etype === 'rate_limit_event' || etype === 'user') {
    return null;
  }

  // Unknown type - show raw
  return (
    <div style={{ color: C.textDim, fontSize: '10px' }}>
      [{etype || 'unknown'}] {JSON.stringify(data).slice(0, 100)}
    </div>
  );
}

export default function LogModal({ loopRunId, onClose, isLive = false }) {
  const [content, setContent] = useState('');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [files, setFiles] = useState([]);
  const [selectedFile, setSelectedFile] = useState(null);
  const [autoScroll, setAutoScroll] = useState(true);
  const logRef = useRef(null);

  const fetchLogs = useCallback(async () => {
    try {
      const tail = isLive ? 200 : 0;
      const res = await fetch(`/api/logs/${loopRunId}?tail=${tail}`);
      const data = await res.json();

      if (data.error) {
        setError(data.error);
      } else {
        setContent(data.content || '');
        setFiles(data.files || []);
        if (!selectedFile && data.file) {
          setSelectedFile(data.file);
        }
        setError(null);
      }
    } catch (e) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  }, [loopRunId, isLive, selectedFile]);

  useEffect(() => {
    fetchLogs();
    if (isLive) {
      const interval = setInterval(fetchLogs, REFRESH_INTERVAL);
      return () => clearInterval(interval);
    }
  }, [fetchLogs, isLive]);

  // Auto-scroll to bottom
  useEffect(() => {
    if (autoScroll && logRef.current) {
      logRef.current.scrollTop = logRef.current.scrollHeight;
    }
  }, [content, autoScroll]);

  const entries = parseLogContent(content);

  return (
    <div style={{
      position: 'fixed', top: 0, left: 0, right: 0, bottom: 0,
      background: 'rgba(0,0,0,0.8)', zIndex: 1000,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
    }} onClick={onClose}>
      <div style={{
        background: C.bg, border: `1px solid ${C.border}`,
        borderRadius: 8, width: '90%', maxWidth: 1000, height: '80vh',
        display: 'flex', flexDirection: 'column',
      }} onClick={e => e.stopPropagation()}>
        {/* Header */}
        <div style={{
          display: 'flex', alignItems: 'center', justifyContent: 'space-between',
          padding: '12px 16px', borderBottom: `1px solid ${C.border}`,
        }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <span style={{ color: C.textBright, fontWeight: 600, fontFamily: FONT }}>
              Logs: {loopRunId}
            </span>
            {isLive && (
              <span style={{
                fontSize: 9, color: '#22c55e', padding: '2px 6px',
                background: 'rgba(34,197,94,0.15)', borderRadius: 3,
              }}>
                LIVE
              </span>
            )}
            {files.length > 1 && (
              <select
                value={selectedFile || ''}
                onChange={e => setSelectedFile(e.target.value)}
                style={{
                  background: C.bgCard, color: C.text, border: `1px solid ${C.border}`,
                  borderRadius: 4, padding: '4px 8px', fontFamily: FONT, fontSize: 11,
                }}
              >
                {files.map(f => <option key={f} value={f}>{f}</option>)}
              </select>
            )}
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <label style={{ display: 'flex', alignItems: 'center', gap: 4, fontSize: 11, color: C.textDim }}>
              <input
                type="checkbox"
                checked={autoScroll}
                onChange={e => setAutoScroll(e.target.checked)}
              />
              Auto-scroll
            </label>
            <button
              onClick={onClose}
              style={{
                background: 'none', border: 'none', color: C.textDim,
                cursor: 'pointer', fontSize: 18, fontFamily: FONT,
              }}
            >
              &times;
            </button>
          </div>
        </div>

        {/* Content */}
        <div
          ref={logRef}
          style={{
            flex: 1, overflow: 'auto', padding: '12px 16px',
            fontFamily: FONT, fontSize: 12, lineHeight: 1.5,
          }}
        >
          {loading && <div style={{ color: C.textDim }}>Loading...</div>}
          {error && <div style={{ color: '#ef4444' }}>Error: {error}</div>}
          {!loading && !error && entries.length === 0 && (
            <div style={{ color: C.textDim }}>No log content</div>
          )}
          {entries.map((entry, i) => (
            <LogEntry key={i} entry={entry} />
          ))}
        </div>
      </div>
    </div>
  );
}
