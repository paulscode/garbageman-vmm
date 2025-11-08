'use client';

import { useEffect, useState } from 'react';

interface LocalArtifact {
  tag: string;
  importedAt: string;
  hasGarbageman: boolean;
  hasKnots: boolean;
  hasContainer: boolean;
  hasBlockchain: boolean;
  path: string;
}

interface ArtifactsViewProps {
  onClose?: () => void;
  onArtifactDeleted?: (tag: string) => void; // Callback when artifact is deleted
  authenticatedFetch: (url: string, options?: RequestInit) => Promise<Response>;
}

export function ArtifactsView({ onClose, onArtifactDeleted, authenticatedFetch }: ArtifactsViewProps) {
  const [artifacts, setArtifacts] = useState<LocalArtifact[]>([]);
  const [loading, setLoading] = useState(true);
  const [deleteConfirm, setDeleteConfirm] = useState<string | null>(null);
  const [deleting, setDeleting] = useState<string | null>(null);

  const fetchArtifacts = async () => {
    try {
      const apiBase = process.env.NEXT_PUBLIC_API_BASE || 'http://localhost:8080';
      const response = await authenticatedFetch(`${apiBase}/api/artifacts`);
      const data = await response.json();
      setArtifacts(data.artifacts || []);
    } catch (error) {
      console.error('Failed to fetch artifacts:', error);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchArtifacts();
  }, []);

  const handleDelete = async (tag: string) => {
    setDeleting(tag);
    try {
      const apiBase = process.env.NEXT_PUBLIC_API_BASE || 'http://localhost:8080';
      const response = await authenticatedFetch(`${apiBase}/api/artifacts/${encodeURIComponent(tag)}`, {
        method: 'DELETE',
      });
      
      if (response.ok) {
        // Remove from list
        setArtifacts(artifacts.filter(a => a.tag !== tag));
        setDeleteConfirm(null);
        // Notify parent component
        if (onArtifactDeleted) {
          onArtifactDeleted(tag);
        }
      } else {
        const error = await response.json();
        alert(`Failed to delete artifact: ${error.message || 'Unknown error'}`);
      }
    } catch (error) {
      console.error('Failed to delete artifact:', error);
      alert('Failed to delete artifact');
    } finally {
      setDeleting(null);
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center py-12">
        <div className="text-tx2 font-mono text-sm">Loading artifacts...</div>
      </div>
    );
  }

  if (artifacts.length === 0) {
    return (
      <div className="flex items-center justify-center py-12">
        <div className="text-tx3 font-mono text-sm">No artifacts imported yet</div>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {artifacts.map((artifact) => (
        <div
          key={artifact.tag}
          className="border-4 border-subtle rounded p-4 hover:border-tx3 transition-colors"
        >
          <div className="flex items-start justify-between gap-4">
            <div className="flex-1 min-w-0">
              <div className="font-mono font-bold text-tx0 text-sm mb-2">
                {artifact.tag}
              </div>
              
              <div className="flex flex-wrap gap-2 mb-2">
                {artifact.hasGarbageman && (
                  <span className="px-2 py-1 bg-acc-green/20 border border-acc-green text-acc-green text-xs font-mono rounded">
                    Garbageman
                  </span>
                )}
                {artifact.hasKnots && (
                  <span className="px-2 py-1 bg-acc-blue/20 border border-acc-blue text-acc-blue text-xs font-mono rounded">
                    Knots
                  </span>
                )}
                {artifact.hasContainer && (
                  <span className="px-2 py-1 bg-accent/20 border border-accent text-accent text-xs font-mono rounded">
                    Container
                  </span>
                )}
                {artifact.hasBlockchain && (
                  <span className="px-2 py-1 bg-acc-red/20 border border-acc-red text-acc-red text-xs font-mono rounded">
                    Blockchain Data
                  </span>
                )}
              </div>
              
              <div className="text-xs text-tx3 font-mono">
                Imported: {new Date(artifact.importedAt).toLocaleString()}
              </div>
            </div>
            
            <div className="flex-shrink-0">
              {deleteConfirm === artifact.tag ? (
                <div className="space-y-2">
                  <div className="text-xs text-tx2 font-mono mb-2">
                    Delete this artifact?
                  </div>
                  <div className="flex gap-2">
                    <button
                      onClick={() => handleDelete(artifact.tag)}
                      disabled={deleting === artifact.tag}
                      className="px-3 py-1 bg-acc-red/20 border-2 border-acc-red text-acc-red hover:bg-acc-red hover:text-bg0 disabled:opacity-50 disabled:cursor-not-allowed text-xs font-mono rounded transition-colors"
                    >
                      {deleting === artifact.tag ? 'Deleting...' : 'Confirm'}
                    </button>
                    <button
                      onClick={() => setDeleteConfirm(null)}
                      disabled={deleting === artifact.tag}
                      className="px-3 py-1 bg-bg3 border-2 border-subtle text-tx2 hover:border-tx3 hover:text-tx0 disabled:opacity-50 disabled:cursor-not-allowed text-xs font-mono rounded transition-colors"
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              ) : (
                <button
                  onClick={() => setDeleteConfirm(artifact.tag)}
                  className="px-3 py-1 bg-bg3 border-2 border-subtle text-tx2 hover:border-acc-red hover:text-acc-red text-xs font-mono rounded transition-colors"
                >
                  Delete
                </button>
              )}
            </div>
          </div>
        </div>
      ))}
    </div>
  );
}
