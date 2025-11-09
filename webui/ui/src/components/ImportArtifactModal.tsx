'use client';

import { API_BASE_URL } from '@/lib/api-config';
/**
 * ImportArtifactModal Component
 * ==============================
 * Modal dialog for importing Bitcoin daemon binaries.
 * 
 * Features:
 *  - Two import methods: File Upload or GitHub Release
 *  - Tab-based interface
 *  - GitHub release list fetching
 *  - File upload with drag-and-drop
 *  - Artifact may contain one or both implementations (detected at import)
 */

import { useState, useEffect } from 'react';
import { cn } from '@/lib/utils';

interface ImportArtifactModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSubmit: (data: ImportArtifactFormData) => void;
  authenticatedFetch: (url: string, options?: RequestInit) => Promise<Response>;
}

export interface ImportArtifactFormData {
  method: 'upload' | 'github';
  // For upload method
  file?: File;
  tag?: string; // e.g., "v29.1.0"
  // For github method
  releaseTag?: string;
  // Whether to download blockchain data
  includeBlockchain?: boolean;
}

interface GitHubRelease {
  tag: string;
  name: string;
  publishedAt: string;
  hasGarbageman: boolean;
  hasKnots: boolean;
  blockchainParts: number;
  hasContainer: boolean;
  hasVM: boolean;
  totalSizeGB: number;
}

export function ImportArtifactModal({ isOpen, onClose, onSubmit, authenticatedFetch }: ImportArtifactModalProps) {
  const [method, setMethod] = useState<'upload' | 'github'>('github');
  const [selectedRelease, setSelectedRelease] = useState<string>('');
  const [uploadedFile, setUploadedFile] = useState<File | null>(null);
  const [uploadTag, setUploadTag] = useState<string>('');
  const [isDragging, setIsDragging] = useState(false);
  const [releases, setReleases] = useState<GitHubRelease[]>([]);
  const [loadingReleases, setLoadingReleases] = useState(false);
  const [includeBlockchain, setIncludeBlockchain] = useState(false);

  // Fetch GitHub releases when modal opens
  useEffect(() => {
    if (isOpen && method === 'github' && releases.length === 0) {
      setLoadingReleases(true);
      authenticatedFetch(`${API_BASE_URL}/api/artifacts/github/releases`)
        .then(res => res.json())
        .then(data => {
          setReleases(data.releases || []);
        })
        .catch(err => {
          console.error('Failed to fetch releases:', err);
        })
        .finally(() => {
          setLoadingReleases(false);
        });
    }
  }, [isOpen, method, releases.length, authenticatedFetch]);

  if (!isOpen) return null;

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    
    if (method === 'github' && !selectedRelease) {
      alert('Please select a release');
      return;
    }
    
    if (method === 'upload' && !uploadedFile) {
      alert('Please upload a file');
      return;
    }
    
    if (method === 'upload' && !uploadTag) {
      alert('Please enter a tag (e.g., v29.1.0)');
      return;
    }

    onSubmit({
      method,
      releaseTag: method === 'github' ? selectedRelease : undefined,
      file: method === 'upload' ? uploadedFile || undefined : undefined,
      tag: method === 'upload' ? uploadTag : undefined,
      includeBlockchain: method === 'github' ? includeBlockchain : false,
    });
  };

  const handleFileSelect = (file: File) => {
    // Validate file type (tar.gz, tar.xz, zip, etc.)
    const validExtensions = ['.tar.gz', '.tar.xz', '.tgz', '.zip'];
    const isValid = validExtensions.some(ext => file.name.endsWith(ext));
    
    if (!isValid) {
      alert('Please upload a valid archive file (.tar.gz, .tar.xz, .zip)');
      return;
    }
    
    setUploadedFile(file);
    
    // Auto-generate tag if not already set
    if (!uploadTag) {
      const now = new Date();
      const timestamp = now.toISOString()
        .replace(/[-:]/g, '')
        .replace(/\.\d{3}Z$/, '')
        .replace('T', '-')
        .slice(0, 15); // Format: YYYYMMDD-HHMMSS
      const autoTag = `upload-${timestamp}`;
      setUploadTag(autoTag);
    }
  };

  const handleDragOver = (e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(true);
  };

  const handleDragLeave = () => {
    setIsDragging(false);
  };

  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(false);
    
    const file = e.dataTransfer.files[0];
    if (file) {
      handleFileSelect(file);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* Backdrop */}
      <div 
        className="absolute inset-0 bg-black/80 backdrop-blur-sm"
        onClick={onClose}
      />
      
      {/* Modal */}
      <div className="relative w-full max-w-3xl mx-4">
        <div className="card border-bright scanlines noise-texture relative overflow-hidden">
          {/* Radioactive Watermark Background */}
          <div className="absolute inset-0 flex items-center justify-center pointer-events-none opacity-5">
            <div className="text-[400px] leading-none select-none">☢</div>
          </div>
          
          {/* Content */}
          <div className="relative z-10">
            {/* Header */}
            <div className="border-b border-subtle p-6">
              <div className="flex items-center justify-between">
                <h2 className="text-2xl font-bold font-mono text-tx0 glow-1">
                  📦 IMPORT ARTIFACT
                </h2>
                <button
                  onClick={onClose}
                  className="text-tx3 hover:text-tx0 transition-colors text-2xl font-mono"
                >
                  ✕
                </button>
              </div>
              <p className="text-sm text-tx3 font-mono mt-2">
                Import Bitcoin daemon binaries from GitHub or local file
              </p>
            </div>

            <form onSubmit={handleSubmit} className="p-6 space-y-6">
              {/* Method Tabs */}
              <div>
                <label className="block text-xs text-tx3 uppercase font-mono mb-2">
                  Import Method *
                </label>
                <div className="grid grid-cols-2 gap-3">
                  <button
                    type="button"
                    onClick={() => setMethod('github')}
                    className={cn(
                      'px-4 py-3 border-4 rounded font-mono font-bold uppercase transition-all',
                      method === 'github'
                        ? 'bg-acc-orange/10 text-tx0 border-acc-orange shadow-lg glow-2 hover:border-tx0'
                        : 'bg-bg2 text-tx2 border-bg3 hover:border-tx0 hover:text-tx0'
                    )}
                  >
                    🐙 GitHub Release
                  </button>
                  <button
                    type="button"
                    onClick={() => setMethod('upload')}
                    className={cn(
                      'px-4 py-3 border-4 rounded font-mono font-bold uppercase transition-all',
                      method === 'upload'
                        ? 'bg-acc-orange/10 text-tx0 border-acc-orange shadow-lg glow-2 hover:border-tx0'
                        : 'bg-bg2 text-tx2 border-bg3 hover:border-tx0 hover:text-tx0'
                    )}
                  >
                    📁 Upload File
                  </button>
                </div>
              </div>

              {/* GitHub Release Selection */}
              {method === 'github' && (
                <div className="space-y-3">
                  <label className="block text-xs text-tx3 uppercase font-mono">
                    Select Release *
                  </label>
                  <div className="max-h-80 overflow-y-auto space-y-2 p-3 bg-bg2 border border-subtle rounded">
                    {loadingReleases ? (
                      <div className="text-center py-8 text-tx3 font-mono">
                        Loading releases...
                      </div>
                    ) : releases.length === 0 ? (
                      <div className="text-center py-8 text-tx3 font-mono">
                        No releases found
                      </div>
                    ) : (
                      releases.map((release) => (
                        <button
                          key={release.tag}
                          type="button"
                          onClick={() => setSelectedRelease(release.tag)}
                          className={cn(
                            'w-full p-4 border-4 rounded font-mono transition-all text-left',
                            selectedRelease === release.tag
                              ? 'bg-acc-orange/10 border-acc-orange text-tx0 glow-1'
                              : 'bg-bg1 border-bg3 text-tx2 hover:border-tx0 hover:text-tx0'
                          )}
                        >
                          <div className="flex items-center justify-between mb-2">
                            <div>
                              <div className="font-bold text-sm">{release.name}</div>
                              <div className="text-xs text-tx3 mt-1">{release.tag}</div>
                            </div>
                            <div className="text-xs text-tx3">
                              {new Date(release.publishedAt).toLocaleDateString()}
                            </div>
                          </div>
                          <div className="flex gap-3 text-xs">
                            {release.hasGarbageman && (
                              <span className="text-acc-green">✓ Garbageman</span>
                            )}
                            {release.hasKnots && (
                              <span className="text-acc-green">✓ Knots</span>
                            )}
                            <span className="text-tx3">{release.totalSizeGB} GB</span>
                            <span className="text-tx3">{release.blockchainParts} parts</span>
                          </div>
                        </button>
                      ))
                    )}
                  </div>
                  <p className="text-xs text-tx3 font-mono">
                    💡 Selecting a release will download and verify the binary
                  </p>
                  
                  {/* Blockchain Download Option */}
                  {selectedRelease && ((releases.find(r => r.tag === selectedRelease)?.blockchainParts || 0) > 0) && (
                    <div className="mt-4 p-4 bg-bg2 border border-subtle rounded">
                      <label className="flex items-start gap-3 cursor-pointer">
                        <input
                          type="checkbox"
                          checked={includeBlockchain}
                          onChange={(e) => setIncludeBlockchain(e.target.checked)}
                          className="mt-1 w-5 h-5 accent-acc-orange"
                        />
                        <div className="flex-1">
                          <div className="text-sm font-mono font-bold text-tx0 mb-1">
                            📦 Include Blockchain Data
                          </div>
                          <div className="text-xs text-tx3 font-mono">
                            Download {releases.find(r => r.tag === selectedRelease)?.blockchainParts} blockchain parts (~{releases.find(r => r.tag === selectedRelease)?.blockchainParts}GB each).
                            This will speed up initial sync for new instances.
                            <br/>
                            <span className="text-amber-500">⚠️ This will take significantly longer to import.</span>
                          </div>
                        </div>
                      </label>
                    </div>
                  )}
                </div>
              )}

              {/* File Upload */}
              {method === 'upload' && (
                <div className="space-y-3">
                  <label className="block text-xs text-tx3 uppercase font-mono">
                    Upload Archive File *
                  </label>
                  <div
                    onDragOver={handleDragOver}
                    onDragLeave={handleDragLeave}
                    onDrop={handleDrop}
                    className={cn(
                      'border-4 border-dashed rounded-lg p-8 transition-all cursor-pointer',
                      isDragging
                        ? 'border-acc-orange bg-acc-orange/10'
                        : uploadedFile
                        ? 'border-acc-green bg-acc-green/10'
                        : 'border-bg3 bg-bg2 hover:border-acc-orange/50'
                    )}
                  >
                    <input
                      type="file"
                      id="file-upload"
                      accept=".tar.gz,.tar.xz,.tgz,.zip"
                      onChange={(e) => {
                        const file = e.target.files?.[0];
                        if (file) handleFileSelect(file);
                      }}
                      className="hidden"
                    />
                    <label htmlFor="file-upload" className="cursor-pointer">
                      <div className="text-center">
                        <div className="text-6xl mb-4">
                          {uploadedFile ? '✅' : isDragging ? '📥' : '📦'}
                        </div>
                        {uploadedFile ? (
                          <>
                            <p className="text-tx0 font-mono font-bold mb-2">{uploadedFile.name}</p>
                            <p className="text-tx3 text-sm font-mono">
                              {(uploadedFile.size / 1024 / 1024).toFixed(2)} MB
                            </p>
                            <button
                              type="button"
                              onClick={(e) => {
                                e.preventDefault();
                                setUploadedFile(null);
                              }}
                              className="mt-4 px-4 py-2 bg-bg3 border border-subtle text-tx2 font-mono rounded hover:border-bright hover:text-tx0 transition-all"
                            >
                              Remove File
                            </button>
                          </>
                        ) : (
                          <>
                            <p className="text-tx0 font-mono font-bold mb-2">
                              {isDragging ? 'Drop file here' : 'Drag & drop archive or click to browse'}
                            </p>
                            <p className="text-tx3 text-sm font-mono">
                              Supported: .tar.gz, .tar.xz, .zip
                            </p>
                          </>
                        )}
                      </div>
                    </label>
                  </div>
                  <p className="text-xs text-tx3 font-mono">
                    ⚠ Archive must contain binaries (bitcoind-gm or bitcoind-knots)
                  </p>
                  <p className="text-xs text-tx3 font-mono mt-1">
                    📋 Files can be in the root or in a single subfolder
                  </p>
                  <p className="text-xs text-tx3 font-mono mt-1">
                    🔍 Garbageman and Knots implementations auto-detected
                  </p>
                  <p className="text-xs text-acc-green font-mono mt-1 font-bold">
                    ✓ Large file support: Files are uploaded in 5MB chunks to avoid timeouts
                  </p>
                  
                  {/* Tag */}
                  <div className="mt-4">
                    <label htmlFor="upload-tag" className="block text-xs text-tx3 uppercase font-mono mb-2">
                      Release Tag *
                    </label>
                    <input
                      type="text"
                      id="upload-tag"
                      value={uploadTag}
                      onChange={(e) => setUploadTag(e.target.value)}
                      placeholder="Auto-generated when file selected"
                      className="w-full px-4 py-3 bg-bg2 border-4 border-bg3 rounded font-mono text-tx0 placeholder-tx3 focus:border-acc-orange focus:outline-none transition-all"
                    />
                    <p className="text-xs text-tx3 font-mono mt-1">
                      Auto-filled with timestamp, but you can edit it
                    </p>
                  </div>
                </div>
              )}

              {/* Submit Buttons */}
              <div className="flex gap-4 pt-4 border-t border-subtle">
                <button
                  type="button"
                  onClick={onClose}
                  className="flex-1 px-6 py-3 bg-bg2 border-4 border-bg3 text-tx2 font-mono font-bold rounded hover:border-tx0 hover:text-tx0 transition-all"
                >
                  CANCEL
                </button>
                <button
                  type="submit"
                  disabled={
                    (method === 'github' && !selectedRelease) ||
                    (method === 'upload' && !uploadedFile)
                  }
                  className={cn(
                    'flex-1 px-6 py-3 font-mono font-bold rounded transition-all border-4',
                    (method === 'github' && selectedRelease) || (method === 'upload' && uploadedFile)
                      ? 'bg-acc-orange/10 text-tx0 border-acc-orange hover:border-tx0 hover:bg-acc-orange/20 shadow-lg glow-2'
                      : 'bg-bg2 text-tx3 border-bg3 cursor-not-allowed opacity-50'
                  )}
                >
                  📦 IMPORT ARTIFACT
                </button>
              </div>
            </form>
          </div>
        </div>
      </div>
    </div>
  );
}
