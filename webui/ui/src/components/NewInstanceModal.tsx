/**
 * NewInstanceModal Component
 * ===========================
 * Modal dialog for creating a new Bitcoin daemon instance.
 * 
 * Features:
 *  - Select from imported artifacts (binaries)
 *  - Choose network (mainnet/testnet/signet/regtest)
 *  - Optional Tor onion address
 *  - Optional custom port overrides
 *  - Auto-generated instance ID
 *  - Link to import new artifacts if none available
 */

'use client';

import { useState, useEffect } from 'react';
import { cn } from '@/lib/utils';

interface Artifact {
  id: string;
  name: string; // e.g., "v2025-11-03-rc2" or "user-upload-2025-11-05"
  implementations: ('garbageman' | 'knots')[]; // Can contain one or both
  path: string;
  uploadedAt: string;
  hasBlockchain?: boolean; // Whether this artifact includes blockchain snapshot data
}

interface NewInstanceModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSubmit: (data: NewInstanceFormData) => void;
  artifacts: Artifact[]; // Available imported binaries
  onImportArtifact?: () => void; // Optional callback to open import modal
}

export interface NewInstanceFormData {
  artifactId: string;
  artifactImpl: 'garbageman' | 'knots';
  network: 'mainnet' | 'testnet' | 'signet' | 'regtest';
  enableClearnet?: boolean; // false = Tor only (default), true = enable clearnet
  useBlockchainSnapshot?: boolean; // true = use blockchain snapshot if available (default), false = resync from scratch
  rpcPort?: number;
  p2pPort?: number;
  zmqPort?: number;
}

export function NewInstanceModal({ isOpen, onClose, onSubmit, artifacts, onImportArtifact }: NewInstanceModalProps) {
  const [formData, setFormData] = useState<NewInstanceFormData>({
    artifactId: artifacts[0]?.id || '',
    artifactImpl: artifacts[0]?.implementations[0] || 'garbageman',
    network: 'mainnet',
    enableClearnet: false, // Default to Tor only
  });

  const [showAdvanced, setShowAdvanced] = useState(false);

  // Reset form when modal opens or artifacts change
  useEffect(() => {
    if (isOpen && artifacts.length > 0) {
      setFormData({
        artifactId: artifacts[0]?.id || '',
        artifactImpl: artifacts[0]?.implementations[0] || 'garbageman',
        network: 'mainnet',
        enableClearnet: false,
        useBlockchainSnapshot: true, // Default to using blockchain snapshot if available
      });
    }
  }, [isOpen, artifacts]);

  if (!isOpen) return null;

  // Get the selected artifact
  const selectedArtifact = artifacts.find(a => a.id === formData.artifactId);
  
  // Check if we have any artifacts at all
  const hasAnyArtifacts = artifacts.length > 0;
  
  // Get available implementations for selected artifact
  const availableImpls = selectedArtifact?.implementations || [];
  
  // Ensure selected impl is available in current artifact
  if (selectedArtifact && !availableImpls.includes(formData.artifactImpl)) {
    setFormData(prev => ({ ...prev, artifactImpl: availableImpls[0] }));
  }

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    onSubmit(formData);
  };

  const handleImportArtifact = () => {
    if (onImportArtifact) {
      onImportArtifact();
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
      <div className="relative w-full max-w-2xl mx-4">
        <div className="card border-bright scanlines noise-texture relative overflow-hidden">
          {/* Radioactive Watermark Background */}
          <div className="absolute inset-0 flex items-center justify-center pointer-events-none opacity-5">
            <div className="text-[400px] leading-none select-none">☢</div>
          </div>
          
          {/* Content (with relative positioning to stay above watermark) */}
          <div className="relative z-10">
            {/* Header */}
            <div className="border-b border-subtle p-6">
              <div className="flex items-center justify-between">
                <h2 className="text-2xl font-bold font-mono text-tx0 glow-1">
                  ⚡ NEW INSTANCE
                </h2>
                <button
                  onClick={onClose}
                  className="text-tx3 hover:text-tx0 transition-colors text-2xl font-mono"
                >
                  ✕
                </button>
              </div>
              <p className="text-sm text-tx3 font-mono mt-2">
                Create a new Bitcoin daemon instance
              </p>
            </div>

          {/* Form */}
          <form onSubmit={handleSubmit} className="p-6 space-y-6">
            {/* Show message if no artifacts */}
            {!hasAnyArtifacts && (
              <div className="p-4 bg-bg2 border border-subtle rounded">
                <p className="text-tx3 font-mono text-sm mb-3">
                  📦 No artifacts imported yet. Import a Bitcoin daemon binary to get started.
                </p>
                <button
                  type="button"
                  onClick={handleImportArtifact}
                  className="px-4 py-2 bg-acc-orange/10 text-tx0 border-4 border-acc-orange font-mono font-bold rounded hover:border-tx0 transition-all glow-1"
                >
                  → IMPORT ARTIFACT
                </button>
              </div>
            )}

            {/* Artifact Selection */}
            {hasAnyArtifacts && (
              <>
                <div>
                  <label className="block text-xs text-tx3 uppercase font-mono mb-2">
                    Artifact (Binary) *
                  </label>
                  <select
                    value={formData.artifactId}
                    onChange={(e) => {
                      const newArtifact = artifacts.find(a => a.id === e.target.value);
                      setFormData({
                        ...formData,
                        artifactId: e.target.value,
                        artifactImpl: newArtifact?.implementations[0] || 'garbageman',
                      });
                    }}
                    className="w-full px-4 py-3 bg-bg2 border border-subtle rounded font-mono text-tx0 focus:border-bright focus:outline-none"
                  >
                    {artifacts.map(artifact => (
                      <option key={artifact.id} value={artifact.id}>
                        {artifact.name}
                      </option>
                    ))}
                  </select>
                  <p className="text-xs text-tx3 font-mono mt-1">
                    💡 Artifact collection containing runtime binaries
                  </p>
                </div>

                {/* Implementation Selection (dynamic based on artifact) */}
                <div>
                  <label className="block text-xs text-tx3 uppercase font-mono mb-2">
                    Implementation *
                  </label>
                  {availableImpls.length > 1 ? (
                    <select
                      value={formData.artifactImpl}
                      onChange={(e) => setFormData({
                        ...formData,
                        artifactImpl: e.target.value as 'garbageman' | 'knots',
                      })}
                      className="w-full px-4 py-3 bg-bg2 border border-subtle rounded font-mono text-tx0 focus:border-bright focus:outline-none"
                    >
                      {availableImpls.map(impl => (
                        <option key={impl} value={impl}>
                          {impl === 'garbageman' ? 'Garbageman' : 'Bitcoin Knots'}
                        </option>
                      ))}
                    </select>
                  ) : (
                    <div className="w-full px-4 py-3 bg-bg2 border border-subtle rounded font-mono text-tx0">
                      {availableImpls[0] === 'garbageman' ? 'Garbageman' : 'Bitcoin Knots'}
                    </div>
                  )}
                  <p className="text-xs text-tx3 font-mono mt-1">
                    {availableImpls.length > 1 
                      ? '📦 This artifact contains both implementations' 
                      : `📦 This artifact contains only ${availableImpls[0] === 'garbageman' ? 'Garbageman' : 'Bitcoin Knots'}`
                    }
                  </p>
                </div>
              </>
            )}

            {/* Network Selection */}
            {hasAnyArtifacts && (
              <>
            <div>
              <label className="block text-xs text-tx3 uppercase font-mono mb-2">
                Network *
              </label>
              <div className="grid grid-cols-2 gap-3">
                {(['mainnet', 'testnet', 'signet', 'regtest'] as const).map((network) => (
                  <button
                    key={network}
                    type="button"
                    onClick={() => setFormData({ ...formData, network })}
                    className={cn(
                      'px-4 py-3 border-4 rounded font-mono font-bold uppercase transition-all',
                      formData.network === network
                        ? 'bg-acc-orange/10 text-tx0 border-acc-orange shadow-lg glow-2 hover:border-tx0'
                        : 'bg-bg2 text-tx2 border-bg3 hover:border-tx0 hover:text-tx0'
                    )}
                  >
                    {network}
                  </button>
                ))}
              </div>
            </div>

            {/* Clearnet Toggle */}
            <div>
              <label className="block text-xs text-tx3 uppercase font-mono mb-2">
                Network Privacy
              </label>
              <div className="flex items-center gap-4 p-4 bg-bg2 border-2 border-subtle rounded">
                                  <button
                    type="button"
                    onClick={() => setFormData({ ...formData, enableClearnet: !formData.enableClearnet })}
                    className={cn(
                      'w-16 h-8 rounded-full transition-all relative flex-shrink-0',
                      'border-4 shadow-lg group',
                      'hover:border-tx0',
                      !formData.enableClearnet
                        ? 'bg-acc-green/40 border-acc-green glow-2'
                        : 'bg-acc-orange/40 border-acc-orange glow-2'
                    )}
                  >
                  <div className={cn(
                    'w-6 h-6 rounded-full transition-all shadow-xl',
                    'absolute top-[1px] border-4',
                    'group-hover:bg-tx0 group-hover:border-tx0',
                    !formData.enableClearnet
                      ? 'left-[1px] bg-acc-green border-acc-green'
                      : 'left-[calc(100%-27px)] bg-acc-orange border-acc-orange'
                  )} />
                </button>
                <div className="flex-1">
                  <div className={cn(
                    "text-sm font-mono font-bold",
                    !formData.enableClearnet ? "text-acc-green" : "text-acc-orange"
                  )}>
                    {!formData.enableClearnet ? '🔒 TOR ONLY' : '🌐 CLEARNET + TOR'}
                  </div>
                  <div className="text-xs text-tx3 font-mono mt-0.5">
                    {!formData.enableClearnet
                      ? 'Maximum privacy • Onion address will be auto-generated'
                      : '⚠ Public IP exposed + Tor onion • Both networks active'
                    }
                  </div>
                </div>
              </div>
            </div>

            {/* Blockchain Snapshot Toggle - Only show if artifact has blockchain data */}
            {selectedArtifact?.hasBlockchain && (
              <div>
                <label className="block text-xs text-tx3 uppercase font-mono mb-2">
                  Initial Blockchain Data
                </label>
                <div className="flex items-center gap-4 p-4 bg-bg2 border-2 border-subtle rounded">
                  <button
                    type="button"
                    onClick={() => setFormData({ ...formData, useBlockchainSnapshot: !formData.useBlockchainSnapshot })}
                    className={cn(
                      'w-16 h-8 rounded-full transition-all relative flex-shrink-0',
                      'border-4 shadow-lg group',
                      'hover:border-tx0',
                      formData.useBlockchainSnapshot
                        ? 'bg-acc-green/40 border-acc-green glow-2'
                        : 'bg-acc-orange/40 border-acc-orange glow-2'
                    )}
                  >
                    <div className={cn(
                      'w-6 h-6 rounded-full transition-all shadow-xl',
                      'absolute top-[1px] border-4',
                      'group-hover:bg-tx0 group-hover:border-tx0',
                      formData.useBlockchainSnapshot
                        ? 'left-[1px] bg-acc-green border-acc-green'
                        : 'left-[calc(100%-27px)] bg-acc-orange border-acc-orange'
                    )} />
                  </button>
                  <div className="flex-1">
                    <div className={cn(
                      "text-sm font-mono font-bold",
                      formData.useBlockchainSnapshot ? "text-acc-green" : "text-acc-orange"
                    )}>
                      {formData.useBlockchainSnapshot ? '⚡ USE SNAPSHOT' : '🔄 RESYNC FROM SCRATCH'}
                    </div>
                    <div className="text-xs text-tx3 font-mono mt-0.5">
                      {formData.useBlockchainSnapshot
                        ? '✓ Extract included blockchain data • Faster startup'
                        : '⏱ Sync from genesis block • Takes hours/days'
                      }
                    </div>
                  </div>
                </div>
              </div>
            )}

            {/* Advanced Options Toggle */}
            <div>
              <button
                type="button"
                onClick={() => setShowAdvanced(!showAdvanced)}
                className="text-sm text-acc-orange hover:text-acc-amber font-mono font-bold transition-colors"
              >
                {showAdvanced ? '▼' : '▶'} ADVANCED OPTIONS
              </button>
            </div>

            {/* Advanced Options */}
            {showAdvanced && (
              <div className="space-y-4 p-4 bg-bg2 border border-subtle rounded">
                <div>
                  <label className="block text-xs text-tx3 uppercase font-mono mb-2">
                    RPC Port (Auto-assigned if blank)
                  </label>
                  <input
                    type="number"
                    value={formData.rpcPort || ''}
                    onChange={(e) => setFormData({ 
                      ...formData, 
                      rpcPort: e.target.value ? parseInt(e.target.value) : undefined 
                    })}
                    placeholder="19000-19999"
                    min="1024"
                    max="65535"
                    className="w-full px-4 py-3 bg-bg1 border border-subtle rounded font-mono text-tx0 placeholder-tx3 focus:border-bright focus:outline-none"
                  />
                </div>

                <div>
                  <label className="block text-xs text-tx3 uppercase font-mono mb-2">
                    P2P Port (Auto-assigned if blank)
                  </label>
                  <input
                    type="number"
                    value={formData.p2pPort || ''}
                    onChange={(e) => setFormData({ 
                      ...formData, 
                      p2pPort: e.target.value ? parseInt(e.target.value) : undefined 
                    })}
                    placeholder="18000-18999"
                    min="1024"
                    max="65535"
                    className="w-full px-4 py-3 bg-bg1 border border-subtle rounded font-mono text-tx0 placeholder-tx3 focus:border-bright focus:outline-none"
                  />
                </div>

                <div>
                  <label className="block text-xs text-tx3 uppercase font-mono mb-2">
                    ZMQ Port (Auto-assigned if blank)
                  </label>
                  <input
                    type="number"
                    value={formData.zmqPort || ''}
                    onChange={(e) => setFormData({ 
                      ...formData, 
                      zmqPort: e.target.value ? parseInt(e.target.value) : undefined 
                    })}
                    placeholder="28000-28999"
                    min="1024"
                    max="65535"
                    className="w-full px-4 py-3 bg-bg1 border border-subtle rounded font-mono text-tx0 placeholder-tx3 focus:border-bright focus:outline-none"
                  />
                </div>

                <p className="text-xs text-tx3 font-mono">
                  ⚠ Ports will be auto-assigned if conflicts detected
                </p>
              </div>
            )}

            {/* Actions */}
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
                disabled={!hasAnyArtifacts}
                className={cn(
                  'flex-1 px-6 py-3 font-mono font-bold rounded transition-all border-4',
                  hasAnyArtifacts
                    ? 'bg-acc-orange/10 text-tx0 border-acc-orange hover:border-tx0 hover:bg-acc-orange/20 shadow-lg glow-2'
                    : 'bg-bg2 text-tx3 border-bg3 cursor-not-allowed opacity-50'
                )}
              >
                ⚡ CREATE INSTANCE
              </button>
            </div>
              </>
            )}
          </form>
          </div> {/* End relative z-10 content wrapper */}
        </div>
      </div>
    </div>
  );
}
