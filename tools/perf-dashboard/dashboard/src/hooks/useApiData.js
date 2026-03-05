import { useState, useEffect, useCallback, useRef } from 'react';

/**
 * Fetches data from the decision server API with polling.
 *
 * When the server is reachable, returns live data from SQLite.
 * When unreachable (plain `npm run dev`), returns null so callers
 * can fall back to static JSON imports.
 *
 * @param {string} endpoint - API path, e.g. '/api/loops'
 * @param {number} pollInterval - ms between fetches (default 5000)
 * @returns {{ data, loading, error, connected, refetch }}
 */
export function useApiData(endpoint, pollInterval = 5000) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [connected, setConnected] = useState(false);
  const mountedRef = useRef(true);

  const fetchData = useCallback(async () => {
    try {
      const res = await fetch(endpoint);
      if (!mountedRef.current) return;
      if (res.ok) {
        const json = await res.json();
        setData(json);
        setError(null);
        setConnected(true);
      } else {
        setError(`HTTP ${res.status}`);
      }
    } catch (e) {
      if (!mountedRef.current) return;
      setError(e.message);
      setConnected(false);
    } finally {
      if (mountedRef.current) setLoading(false);
    }
  }, [endpoint]);

  useEffect(() => {
    mountedRef.current = true;
    fetchData();
    const interval = setInterval(fetchData, pollInterval);
    return () => {
      mountedRef.current = false;
      clearInterval(interval);
    };
  }, [fetchData, pollInterval]);

  return { data, loading, error, connected, refetch: fetchData };
}

/**
 * Combines API data with static fallback.
 * Returns live data when server is reachable, static data otherwise.
 *
 * Usage:
 *   import FALLBACK from './data/loops.json';
 *   const loops = useLiveData('/api/loops', FALLBACK);
 */
export function useLiveData(endpoint, fallback, pollInterval = 5000) {
  const { data, connected, loading } = useApiData(endpoint, pollInterval);
  if (loading) return null;
  return connected && data !== null ? data : fallback;
}
