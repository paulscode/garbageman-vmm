/**
 * Home Page - Garbageman Nodes Manager
 * ======================================
 * Main dashboard showing all daemon instances and system status.
 * War room control center with neon orange accents.
 */

'use client';

import { useState, useEffect, useRef } from 'react';
import { CommandBar } from '@/components/CommandBar';
import { StatusBoard } from '@/components/StatusBoard';
import { NodeCard } from '@/components/NodeCard';
import { AlertsRail } from '@/components/AlertsRail';
import { Dashboard } from '@/components/Dashboard';
import { NewInstanceModal, type NewInstanceFormData } from '@/components/NewInstanceModal';
import { ImportArtifactModal, type ImportArtifactFormData } from '@/components/ImportArtifactModal';
import { PasswordDialog } from '@/components/PasswordDialog';
import { ToastContainer } from '@/components/Toast';
import { useToast } from '@/hooks/useToast';
import { PeerListModal } from '@/components/PeerListModal';
import { ArtifactsView } from '@/components/ArtifactsView';

// Type for instance detail (matches API response)
interface InstanceConfig {
  INSTANCE_ID: string;
  RPC_PORT: number;
  P2P_PORT: number;
  ZMQ_PORT: number;
  TOR_ONION?: string;
  BITCOIN_IMPL?: 'garbageman' | 'knots';
  NETWORK?: 'mainnet' | 'testnet' | 'signet' | 'regtest';
  RPC_USER?: string;
  RPC_PASS?: string;
}

interface InstanceStatus {
  id: string;
  state: 'up' | 'exited' | 'starting' | 'stopping';
  impl: 'garbageman' | 'knots';
  version?: string;
  network: 'mainnet' | 'testnet' | 'signet' | 'regtest';
  uptime: number;
  peers: number;
  peerBreakdown?: {
    libreRelay: number;
    knots: number;
    oldCore: number;
    newCore: number;
    other: number;
  };
  blocks: number;
  headers: number;
  progress: number;
  initialBlockDownload?: boolean;
  diskGb: number;
  rpcPort: number;
  p2pPort: number;
  onion?: string;
  ipv4Enabled: boolean;
  kpiTags: string[];
}

interface InstanceDetail {
  config: InstanceConfig;
  status: InstanceStatus;
}

export default function HomePage() {
  const [isLocked, setIsLocked] = useState(true); // Start locked
  const [isAuthenticating, setIsAuthenticating] = useState(false); // Loading screen during auth
  const [instances, setInstances] = useState<InstanceDetail[]>([]);
  const [loading, setLoading] = useState(true);
  const [health, setHealth] = useState<'ok' | 'degraded' | 'error'>('ok');
  const [version, setVersion] = useState<string>('0.1.0'); // API version
  const [showNewInstanceModal, setShowNewInstanceModal] = useState(false);
  const [showImportArtifactModal, setShowImportArtifactModal] = useState(false);
  const [showPeerListModal, setShowPeerListModal] = useState(false);
  const [currentView, setCurrentView] = useState<'instances' | 'dashboard' | 'artifacts'>('instances');
  
  // Toast notifications
  const { toasts, addToast, updateToast, dismissToast } = useToast();
  
  // Import progress tracking
  const [importingArtifact, setImportingArtifact] = useState<string | null>(null);
  const importProgressToastId = useRef<string | null>(null);
  const importProgressInterval = useRef<NodeJS.Timeout | null>(null);
  
  // Artifacts (fetched from API)
  const [artifacts, setArtifacts] = useState<Array<{
    id: string;
    name: string;
    implementations: ('garbageman' | 'knots')[];
    path: string;
    uploadedAt: string;
    hasBlockchain?: boolean;
  }>>([]);
  
  // Helper function to make authenticated API requests
  const authenticatedFetch = async (url: string, options: RequestInit = {}) => {
    const token = sessionStorage.getItem('auth_token');
    
    if (!token) {
      // Token missing - user needs to re-authenticate
      setIsLocked(true);
      throw new Error('Authentication required');
    }
    
    // Add Authorization header
    const headers = {
      ...options.headers,
      'Authorization': `Bearer ${token}`,
    };
    
    const response = await fetch(url, { ...options, headers });
    
    // If 401, token expired - lock UI
    if (response.status === 401) {
      sessionStorage.removeItem('auth_token');
      setIsLocked(true);
      throw new Error('Session expired');
    }
    
    return response;
  };
  
  // Load instances on mount
  useEffect(() => {
    const loadInstances = async (showLoading = false) => {
      // Skip if locked
      if (isLocked) return;
      
      try {
        if (showLoading) setLoading(true);
        
        // Fetch from real API with authentication
        const response = await authenticatedFetch('http://localhost:8080/api/instances');
        if (!response.ok) {
          throw new Error(`API error: ${response.status}`);
        }
        const data = await response.json();
        setInstances(data.instances);
        setHealth('ok');
      } catch (error) {
        console.error('Failed to load instances:', error);
        setHealth('error');
        setInstances([]);
      } finally {
        if (showLoading) setLoading(false);
      }
    };
    
    // Initial load with loading indicator
    loadInstances(true);
    
    // Fetch version from health endpoint
    const fetchVersion = async () => {
      try {
        const response = await fetch('http://localhost:8080/api/health');
        if (response.ok) {
          const data = await response.json();
          if (data.version) {
            setVersion(data.version);
          }
        }
      } catch (error) {
        console.error('Failed to fetch version:', error);
      }
    };
    fetchVersion();
    
    // Poll every 5 seconds to keep status fresh (without loading indicator)
    const interval = setInterval(() => loadInstances(false), 5000);
    
    return () => clearInterval(interval);
  }, [isLocked]);
  
  // Load artifacts on mount
  useEffect(() => {
    const loadArtifacts = async () => {
      // Skip if locked
      if (isLocked) return;
      
      try {
        const response = await authenticatedFetch('http://localhost:8080/api/artifacts');
        if (!response.ok) {
          throw new Error(`API error: ${response.status}`);
        }
        const data = await response.json();
        
        // Transform API response to match our interface
        const transformedArtifacts = data.artifacts.map((a: any) => ({
          id: `artifact-${a.tag}`,
          name: a.tag,
          implementations: [
            ...(a.hasGarbageman ? ['garbageman' as const] : []),
            ...(a.hasKnots ? ['knots' as const] : []),
          ],
          path: a.path,
          uploadedAt: a.importedAt,
          hasBlockchain: a.hasBlockchain || false,
        }));
        
        setArtifacts(transformedArtifacts);
      } catch (error) {
        console.error('Failed to load artifacts:', error);
        setArtifacts([]);
      }
    };
    
    loadArtifacts();
  }, [isLocked]);
  
  // Handlers for instance actions
  const handleStart = async (id: string) => {
    console.log('Start instance:', id);
    
    try {
      const response = await authenticatedFetch(`http://localhost:8080/api/instances/${id}/start`, {
        method: 'POST',
      });
      
      if (!response.ok) {
        throw new Error(`API error: ${response.status}`);
      }
      
      const result = await response.json();
      console.log('Instance started:', result);
      
      // Reload instances to reflect new state
      const listResponse = await authenticatedFetch('http://localhost:8080/api/instances');
      const listData = await listResponse.json();
      setInstances(listData.instances);
      
      addToast('success', 'Instance Started', `${id} is now running`, { duration: 8000 });
    } catch (error) {
      console.error('Failed to start instance:', error);
      addToast('error', 'Start Failed', error instanceof Error ? error.message : 'Failed to start instance', { duration: 10000 });
    }
  };
  
  const handleStop = async (id: string) => {
    console.log('Stop instance:', id);
    
    try {
      const response = await authenticatedFetch(`http://localhost:8080/api/instances/${id}/stop`, {
        method: 'POST',
      });
      
      if (!response.ok) {
        throw new Error(`API error: ${response.status}`);
      }
      
      const result = await response.json();
      console.log('Instance stopped:', result);
      
      // Reload instances to reflect new state
      const listResponse = await authenticatedFetch('http://localhost:8080/api/instances');
      const listData = await listResponse.json();
      setInstances(listData.instances);
      
      addToast('success', 'Instance Deleted', `${id} has been removed`, { duration: 8000 });
    } catch (error) {
      console.error('Failed to delete instance:', error);
      addToast('error', 'Delete Failed', error instanceof Error ? error.message : 'Failed to delete instance', { duration: 10000 });
    }
  };
  
  const handleDelete = async (id: string) => {
    console.log('Delete instance:', id);
    const confirmed = confirm(`Delete instance ${id}?`);
    if (!confirmed) return;
    
    try {
      const response = await authenticatedFetch(`http://localhost:8080/api/instances/${id}`, {
        method: 'DELETE',
      });
      
      if (!response.ok) {
        throw new Error(`API error: ${response.status}`);
      }
      
      // Remove from local state
      setInstances(prev => prev.filter(i => i.config.INSTANCE_ID !== id));
      
      addToast('success', 'Instance Deleted', `${id} has been removed`, { duration: 5000 });
    } catch (error) {
      console.error('Failed to delete instance:', error);
      addToast('error', 'Delete Failed', error instanceof Error ? error.message : 'Failed to delete instance', { duration: 7000 });
    }
  };
  
  const handleCreateInstance = () => {
    console.log('Create new instance');
    setShowNewInstanceModal(true);
  };
  
  const handleArtifactDeleted = (tag: string) => {
    // Remove deleted artifact from local state
    setArtifacts(prev => prev.filter(a => a.id !== tag));
  };
  
  const handleCreateInstanceSubmit = async (data: NewInstanceFormData) => {
    // Validate artifact selection
    if (!data.artifactId) {
      addToast('error', 'Validation Error', 'Please select an artifact');
      return;
    }
    
    // Get the selected artifact to check for blockchain data
    const selectedArtifact = artifacts.find(a => a.id === data.artifactId);
    if (!selectedArtifact) {
      addToast('error', 'Validation Error', 'Selected artifact not found');
      return;
    }
    
    // Determine progress message based on blockchain snapshot usage
    const useBlockchain = data.useBlockchainSnapshot !== false;
    const hasBlockchain = selectedArtifact.hasBlockchain;
    const progressMessage = hasBlockchain && useBlockchain
      ? 'Setting up instance and extracting blockchain snapshot...'
      : 'Setting up instance...';
    
    // Show progress toast before closing modal
    const progressToastId = addToast(
      'info',
      'Creating Instance',
      progressMessage,
      { 
        duration: 0, // 0 means no auto-dismiss
        showProgress: true,
      }
    );
    
    // Close modal after brief delay to ensure toast renders
    setTimeout(() => {
      setShowNewInstanceModal(false);
    }, 100);
    
    try {
      // Call API to create instance (use tag name, not the transformed ID)
      const response = await authenticatedFetch('http://localhost:8080/api/instances', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          artifact: selectedArtifact.name, // Use the tag name (e.g., "v2025-11-03-rc2")
          implementation: data.artifactImpl,
          // Version will be queried from running daemon and saved
          network: data.network,
          ipv4Enabled: data.enableClearnet || false,
          useBlockchainSnapshot: data.useBlockchainSnapshot !== false, // default to true
          rpcPort: data.rpcPort,
          p2pPort: data.p2pPort,
          zmqPort: data.zmqPort,
        }),
      });
      
      if (!response.ok) {
        const errorData = await response.json().catch(() => ({}));
        dismissToast(progressToastId);
        throw new Error(errorData.message || `API error: ${response.status}`);
      }
      
      const result = await response.json();
      console.log('Instance created:', result);
      
      // Dismiss progress toast
      dismissToast(progressToastId);
      
      // Reload instances to show the new one
      const listResponse = await authenticatedFetch('http://localhost:8080/api/instances');
      const listData = await listResponse.json();
      setInstances(listData.instances);
      
      addToast('success', 'Instance Created!', `${result.instanceId} is ready`, { duration: 10000 });
      
    } catch (error) {
      console.error('Failed to create instance:', error);
      addToast('error', 'Creation Failed', error instanceof Error ? error.message : 'Failed to create instance', { duration: 12000 });
    }
  };
  
  const handleImportArtifact = () => {
    console.log('Import artifact');
    setShowImportArtifactModal(true);
  };
  
  const handleImportArtifactSubmit = async (data: ImportArtifactFormData) => {
    console.log('Importing artifact with data:', data);
    
    try {
      if (data.method === 'github' && data.releaseTag) {
        setShowImportArtifactModal(false);
        setImportingArtifact(data.releaseTag);
        
        // Create progress toast
        const toastId = addToast(
          'progress',
          `Importing ${data.releaseTag}`,
          data.includeBlockchain ? 'Including blockchain data - this will take longer' : 'Downloading binaries and container image',
          { progress: 0 }
        );
        importProgressToastId.current = toastId;
        
        // Start import and check response
        authenticatedFetch('http://localhost:8080/api/artifacts/github/import', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            tag: data.releaseTag,
            skipBlockchain: !data.includeBlockchain,
          }),
        }).then(async (importResponse) => {
          if (!importResponse.ok && importResponse.status !== 409) {
            const importResult = await importResponse.json();
            // Check if already exists
            if (importResult.alreadyExists) {
              if (importProgressInterval.current) {
                clearInterval(importProgressInterval.current);
                importProgressInterval.current = null;
              }
              dismissToast(toastId);
              addToast(
                'info',
                'Already Imported',
                `${data.releaseTag} is already available`,
                { duration: 10000 }
              );
              setImportingArtifact(null);
              
              // Reload artifacts
              const artifactsResponse = await authenticatedFetch('http://localhost:8080/api/artifacts');
              const artifactsData = await artifactsResponse.json();
              const transformedArtifacts = artifactsData.artifacts.map((a: any) => ({
                id: `artifact-${a.tag}`,
                name: a.tag,
                implementations: [
                  ...(a.hasGarbageman ? ['garbageman' as const] : []),
                  ...(a.hasKnots ? ['knots' as const] : []),
                ],
                path: a.path,
                uploadedAt: a.importedAt,
                hasBlockchain: a.hasBlockchain || false,
              }));
              setArtifacts(transformedArtifacts);
            } else {
              throw new Error(`Import failed: ${importResponse.status}`);
            }
          } else if (importResponse.status === 409) {
            // Import already in progress
            if (importProgressInterval.current) {
              clearInterval(importProgressInterval.current);
              importProgressInterval.current = null;
            }
            dismissToast(toastId);
            addToast(
              'warning',
              'Import In Progress',
              `${data.releaseTag} is already being downloaded`,
              { duration: 10000 }
            );
            setImportingArtifact(null);
          }
        }).catch(error => {
          console.error('Import request failed:', error);
          if (importProgressInterval.current) {
            clearInterval(importProgressInterval.current);
            importProgressInterval.current = null;
          }
          dismissToast(toastId);
          addToast('error', 'Import Failed', error.message || 'Failed to start import', { duration: 12000 });
          setImportingArtifact(null);
        });
        
        // Start polling for progress immediately
        importProgressInterval.current = setInterval(async () => {
          try {
            const progressResponse = await authenticatedFetch(
              `http://localhost:8080/api/artifacts/import/progress/${data.releaseTag}`
            );
            
            console.log('Progress poll response status:', progressResponse.status);
            
            if (!progressResponse.ok) {
              // Import might be complete or not started yet
              if (progressResponse.status === 404) {
                // Check if artifact exists now (import complete)
                const artifactsResponse = await authenticatedFetch('http://localhost:8080/api/artifacts');
                const artifactsData = await artifactsResponse.json();
                const imported = artifactsData.artifacts.find((a: any) => a.tag === data.releaseTag);
                
                if (imported) {
                  // Import completed!
                  if (importProgressInterval.current) {
                    clearInterval(importProgressInterval.current);
                    importProgressInterval.current = null;
                  }
                  
                  dismissToast(toastId);
                  addToast(
                    'success',
                    'Import Complete!',
                    `${data.releaseTag} is ready to use`,
                    { duration: 10000 }
                  );
                  
                  // Reload artifacts
                  const transformedArtifacts = artifactsData.artifacts.map((a: any) => ({
                    id: `artifact-${a.tag}`,
                    name: a.tag,
                    implementations: [
                      ...(a.hasGarbageman ? ['garbageman' as const] : []),
                      ...(a.hasKnots ? ['knots' as const] : []),
                    ],
                    path: a.path,
                    uploadedAt: a.importedAt,
                    hasBlockchain: a.hasBlockchain || false,
                  }));
                  setArtifacts(transformedArtifacts);
                  setImportingArtifact(null);
                }
              }
              return;
            }
            
            const progress = await progressResponse.json();
            console.log('Progress data:', progress);
            
            // Update toast with current progress
            let message = progress.currentFile || 'Processing...';
            if (progress.status === 'reassembling') {
              message = 'Reassembling blockchain data...';
            }
            
            console.log('Updating toast:', toastId, 'with progress:', progress.progress);
            updateToast(toastId, {
              message: `${message} (${progress.downloadedFiles}/${progress.totalFiles} files)`,
              progress: progress.progress,
            });
            
            // Check if complete
            if (progress.status === 'complete') {
              if (importProgressInterval.current) {
                clearInterval(importProgressInterval.current);
                importProgressInterval.current = null;
              }
              
              dismissToast(toastId);
              addToast(
                'success',
                'Import Complete!',
                `${data.releaseTag} is ready to use`,
                { duration: 10000 }
              );
              
              // Reload artifacts
              const artifactsResponse = await authenticatedFetch('http://localhost:8080/api/artifacts');
              const artifactsData = await artifactsResponse.json();
              const transformedArtifacts = artifactsData.artifacts.map((a: any) => ({
                id: `artifact-${a.tag}`,
                name: a.tag,
                implementations: [
                  ...(a.hasGarbageman ? ['garbageman' as const] : []),
                  ...(a.hasKnots ? ['knots' as const] : []),
                ],
                path: a.path,
                uploadedAt: a.importedAt,
                hasBlockchain: a.hasBlockchain || false,
              }));
              setArtifacts(transformedArtifacts);
              setImportingArtifact(null);
            } else if (progress.status === 'error') {
              if (importProgressInterval.current) {
                clearInterval(importProgressInterval.current);
                importProgressInterval.current = null;
              }
              
              dismissToast(toastId);
              addToast('error', 'Import Failed', progress.error || 'Unknown error', { duration: 10000 });
              setImportingArtifact(null);
            }
          } catch (error) {
            console.error('Progress check failed:', error);
          }
        }, 1000); // Poll every second
        
      } else if (data.method === 'upload' && data.file) {
        // File upload method
        setShowImportArtifactModal(false);
        
        const uploadToastId = addToast(
          'progress',
          'Uploading Artifact',
          `Uploading ${data.file.name}...`,
          { showProgress: true } // Use indeterminate progress since we can't track upload progress
        );
        
        try {
          // Create FormData for file upload
          // IMPORTANT: Append tag BEFORE file so multipart parser captures it
          const formData = new FormData();
          formData.append('tag', data.tag || 'unknown');
          formData.append('file', data.file);
          
          console.log('About to send fetch request to /api/artifacts/import');
          console.log('FormData contents:', { file: data.file.name, tag: data.tag || 'unknown' });
          
          // Upload file - use direct API URL to bypass Next.js proxy size limits
          // For large files, Next.js proxy can truncate the upload
          const apiUrl = process.env.NEXT_PUBLIC_API_BASE || 'http://localhost:8080';
          const uploadResponse = await authenticatedFetch(`${apiUrl}/api/artifacts/import`, {
            method: 'POST',
            body: formData,
          });
          
          console.log('Fetch completed, response status:', uploadResponse.status);
          
          dismissToast(uploadToastId);
          
          if (!uploadResponse.ok) {
            const errorData = await uploadResponse.json();
            addToast(
              'error',
              'Upload Failed',
              errorData.message || 'Failed to upload artifact',
              { duration: 12000 }
            );
            return;
          }
          
          const result = await uploadResponse.json();
          
          if (result.success) {
            const impls = [];
            if (result.artifact?.hasGarbageman) impls.push('Garbageman');
            if (result.artifact?.hasKnots) impls.push('Knots');
            
            addToast(
              'success',
              'Upload Complete',
              `${result.artifact?.tag} imported with ${impls.join(' and ')}`,
              { duration: 10000 }
            );
            
            // Reload artifacts
            const artifactsResponse = await authenticatedFetch('http://localhost:8080/api/artifacts');
            const artifactsData = await artifactsResponse.json();
            const transformedArtifacts = artifactsData.artifacts.map((a: any) => ({
              id: `artifact-${a.tag}`,
              name: a.tag,
              implementations: [
                ...(a.hasGarbageman ? ['garbageman' as const] : []),
                ...(a.hasKnots ? ['knots' as const] : []),
              ],
              path: a.path,
              uploadedAt: a.importedAt,
              hasBlockchain: a.hasBlockchain || false,
            }));
            setArtifacts(transformedArtifacts);
          } else {
            addToast(
              'error',
              'Upload Failed',
              result.message || 'Unknown error',
              { duration: 12000 }
            );
          }
        } catch (error) {
          dismissToast(uploadToastId);
          console.error('File upload failed:', error);
          addToast(
            'error',
            'Upload Failed',
            error instanceof Error ? error.message : 'Failed to upload file',
            { duration: 12000 }
          );
        }
      }
    } catch (error) {
      console.error('Failed to import artifact:', error);
      addToast('error', 'Import Failed', error instanceof Error ? error.message : 'Unknown error', { duration: 12000 });
    }
  };
  
  // Password unlock handler
  const handleUnlock = async (password: string) => {
    try {
      const startTime = Date.now();
      
      // Call server-side authentication endpoint
      const response = await fetch('http://localhost:8080/api/auth/login', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ password }),
      });
      
      const data = await response.json();
      
      if (data.success && data.token) {
        // Store JWT token in sessionStorage (cleared on browser close)
        sessionStorage.setItem('auth_token', data.token);
        
        // Unlock immediately to dismiss password dialog and show loading screen
        setIsLocked(false);
        setIsAuthenticating(true);
        
        // Ensure loading screen shows for at least 1 second
        const elapsed = Date.now() - startTime;
        const minLoadingTime = 1000; // 1 second minimum
        const remainingTime = Math.max(0, minLoadingTime - elapsed);
        
        await new Promise(resolve => setTimeout(resolve, remainingTime));
        
        setIsAuthenticating(false);
        addToast('success', 'Authenticated', 'Access granted', { duration: 3000 });
      } else {
        // Authentication failed
        addToast('error', 'Access Denied', data.message || 'Invalid password', { duration: 5000 });
      }
    } catch (error) {
      console.error('Authentication error:', error);
      addToast('error', 'Connection Error', 'Failed to connect to API server', { duration: 5000 });
    }
  };
  
  // Show loading screen during initial load or authentication
  if (loading || isAuthenticating) {
    return (
      <>
        <PasswordDialog isLocked={isLocked} onUnlock={handleUnlock} />
        <div className="min-h-screen bg-bg0 flex items-center justify-center">
        <div className="text-center space-y-4">
          <div className="animate-pulse-glow text-accent text-2xl font-mono font-bold">
            LOADING SYSTEMS...
          </div>
          <div className="text-tx3 text-sm font-mono uppercase">
            Initializing war room interface
          </div>
        </div>
      </div>
      </>
    );
  }
  
  return (
    <>
      <PasswordDialog isLocked={isLocked} onUnlock={handleUnlock} />
      <ToastContainer toasts={toasts} onDismiss={dismissToast} />
    <div className="min-h-screen bg-bg0 scanlines noise-texture">
      {/* Command Bar */}
      <CommandBar
        health={health}
        onCreateInstance={handleCreateInstance}
        onImportArtifact={handleImportArtifact}
        onViewPeers={() => setShowPeerListModal(true)}
      />
      
      {/* Main Content Area */}
      <main className="container mx-auto px-4 py-8">
        {/* View Tabs */}
        <div className="flex gap-4 mb-8 border-b border-subtle">
          <button
            onClick={() => setCurrentView('instances')}
            className={`px-6 py-3 font-mono text-sm uppercase tracking-wider transition-all ${
              currentView === 'instances'
                ? 'text-accent border-b-2 border-accent font-bold'
                : 'text-tx3 hover:text-tx1'
            }`}
          >
            Instances
          </button>
          <button
            onClick={() => setCurrentView('dashboard')}
            className={`px-6 py-3 font-mono text-sm uppercase tracking-wider transition-all ${
              currentView === 'dashboard'
                ? 'text-accent border-b-2 border-accent font-bold'
                : 'text-tx3 hover:text-tx1'
            }`}
          >
            Dashboard
          </button>
          <button
            onClick={() => setCurrentView('artifacts')}
            className={`px-6 py-3 font-mono text-sm uppercase tracking-wider transition-all ${
              currentView === 'artifacts'
                ? 'text-accent border-b-2 border-accent font-bold'
                : 'text-tx3 hover:text-tx1'
            }`}
          >
            Artifacts
          </button>
        </div>

        {currentView === 'dashboard' ? (
          <Dashboard authenticatedFetch={authenticatedFetch} />
        ) : currentView === 'artifacts' ? (
          <ArtifactsView onArtifactDeleted={handleArtifactDeleted} authenticatedFetch={authenticatedFetch} />
        ) : (
        <div className="grid grid-cols-1 lg:grid-cols-4 gap-8">
          {/* Left Column: Status Board + Instance Grid */}
          <div className="lg:col-span-3 space-y-8">
            {/* Status Board */}
            <section>
              <h2 className="text-2xl font-bold text-gradient-orange font-mono mb-6 uppercase tracking-wider">
                Mission Status
              </h2>
              <StatusBoard instances={instances} />
            </section>
            
            {/* Instance Grid */}
            <section>
              <h2 className="text-2xl font-bold text-gradient-orange font-mono mb-6 uppercase tracking-wider">
                Active Nodes
              </h2>
              
              {instances.length === 0 ? (
                <div className="card text-center py-12">
                  <p className="text-tx3 font-mono text-lg">
                    NO INSTANCES CONFIGURED
                  </p>
                  <button
                    onClick={handleCreateInstance}
                    className="btn-primary mt-4"
                  >
                    <span className="font-mono">CREATE FIRST INSTANCE</span>
                  </button>
                </div>
              ) : (
                <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                  {instances.map((instance) => (
                    <NodeCard
                      key={instance.config.INSTANCE_ID}
                      instance={instance}
                      onStart={handleStart}
                      onStop={handleStop}
                      onDelete={handleDelete}
                    />
                  ))}
                </div>
              )}
            </section>
          </div>
          
          {/* Right Column: Alerts Rail */}
          <div className="lg:col-span-1">
            <AlertsRail authenticatedFetch={authenticatedFetch} />
          </div>
        </div>
        )}
      </main>
      
      {/* Footer */}
      <footer className="border-t border-border mt-16 py-6">
        <div className="container mx-auto px-4 text-center">
          <p className="text-xs text-tx3 font-mono uppercase tracking-wider">
            Garbageman Nodes Manager v{version}
          </p>
          <p className="text-xs text-tx3 font-mono mt-1">
            Paul Lamb • {new Date().getFullYear()}
          </p>
        </div>
      </footer>
      
      {/* New Instance Modal */}
      <NewInstanceModal
        isOpen={showNewInstanceModal}
        onClose={() => setShowNewInstanceModal(false)}
        onSubmit={handleCreateInstanceSubmit}
        artifacts={artifacts}
        onImportArtifact={() => {
          setShowNewInstanceModal(false);
          setShowImportArtifactModal(true);
        }}
      />
      
      {/* Import Artifact Modal */}
      <ImportArtifactModal
        isOpen={showImportArtifactModal}
        onClose={() => setShowImportArtifactModal(false)}
        onSubmit={handleImportArtifactSubmit}
        authenticatedFetch={authenticatedFetch}
      />
      
      {/* Peer List Modal */}
      <PeerListModal
        isOpen={showPeerListModal}
        onClose={() => setShowPeerListModal(false)}
        authenticatedFetch={authenticatedFetch}
      />
    </div>
    </>
  );
}
