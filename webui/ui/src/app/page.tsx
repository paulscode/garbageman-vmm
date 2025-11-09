/**
 * Home Page - Garbageman Nodes Manager
 * ======================================
 * Main dashboard showing all daemon instances and system status.
 * War room control center with neon orange accents.
 */

'use client';

import { API_BASE_URL } from '@/lib/api-config';
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

interface ApiArtifact {
  tag: string;
  hasGarbageman: boolean;
  hasKnots: boolean;
  hasContainer: boolean;
  hasBlockchain: boolean;
  path: string;
  importedAt: string;
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
  
  // Instance creation progress tracking
  const [extractingInstance, setExtractingInstance] = useState<string | null>(null);
  const extractionProgressToastId = useRef<string | null>(null);
  const extractionProgressInterval = useRef<NodeJS.Timeout | null>(null);
  
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
        const response = await authenticatedFetch(`${API_BASE_URL}/api/instances`);
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
        const response = await fetch(`${API_BASE_URL}/api/health`);
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
        const response = await authenticatedFetch(`${API_BASE_URL}/api/artifacts`);
        if (!response.ok) {
          throw new Error(`API error: ${response.status}`);
        }
        const data = await response.json();
        
        // Transform API response to match our interface
        const transformedArtifacts = data.artifacts.map((a: ApiArtifact) => ({
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
      const response = await authenticatedFetch(`${API_BASE_URL}/api/instances/${id}/start`, {
        method: 'POST',
      });
      
      if (!response.ok) {
        throw new Error(`API error: ${response.status}`);
      }
      
      const result = await response.json();
      console.log('Instance started:', result);
      
      // Reload instances to reflect new state
      const listResponse = await authenticatedFetch(`${API_BASE_URL}/api/instances`);
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
      const response = await authenticatedFetch(`${API_BASE_URL}/api/instances/${id}/stop`, {
        method: 'POST',
      });
      
      if (!response.ok) {
        throw new Error(`API error: ${response.status}`);
      }
      
      const result = await response.json();
      console.log('Instance stopped:', result);
      
      // Reload instances to reflect new state
      const listResponse = await authenticatedFetch(`${API_BASE_URL}/api/instances`);
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
      const response = await authenticatedFetch(`${API_BASE_URL}/api/instances/${id}`, {
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
      const response = await authenticatedFetch(`${API_BASE_URL}/api/instances`, {
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
      
      // Check if blockchain extraction is in progress (202 status)
      if (response.status === 202) {
        // Blockchain extraction is happening in background
        // Update the progress toast and start polling
        dismissToast(progressToastId);
        
        const toastId = addToast(
          'info',
          `Creating ${result.instanceId}`,
          'Extracting blockchain data - this may take 10-30 minutes',
          { 
            duration: 0, // Don't auto-dismiss
            showProgress: true, // Show animated indeterminate bar
          }
        );
        extractionProgressToastId.current = toastId;
        setExtractingInstance(result.instanceId);
        
        // Start polling for extraction progress
        extractionProgressInterval.current = setInterval(async () => {
          try {
            const progressResponse = await authenticatedFetch(
              `${API_BASE_URL}/api/instances/extraction/progress/${result.instanceId}`
            );
            
            if (!progressResponse.ok) {
              // Extraction might be complete
              if (progressResponse.status === 404) {
                // Check if instance exists now (extraction complete)
                const instancesResponse = await authenticatedFetch(`${API_BASE_URL}/api/instances`);
                const instancesData = await instancesResponse.json();
                const created = instancesData.instances.find((i: any) => i.config.INSTANCE_ID === result.instanceId);
                
                if (created) {
                  // Extraction completed!
                  if (extractionProgressInterval.current) {
                    clearInterval(extractionProgressInterval.current);
                    extractionProgressInterval.current = null;
                  }
                  
                  dismissToast(toastId);
                  addToast(
                    'success',
                    'Instance Ready!',
                    `${result.instanceId} has been created with blockchain data`,
                    { duration: 10000 }
                  );
                  
                  // Reload instances
                  setInstances(instancesData.instances);
                  setExtractingInstance(null);
                }
              }
              return;
            }
            
            const progress = await progressResponse.json();
            console.log('Extraction progress:', progress);
            
            // Update toast with current status
            updateToast(toastId, {
              title: `Creating ${result.instanceId}`,
              message: progress.message || 'Extracting blockchain data...',
            });
            
            // Check if complete or error
            if (progress.status === 'complete') {
              if (extractionProgressInterval.current) {
                clearInterval(extractionProgressInterval.current);
                extractionProgressInterval.current = null;
              }
              
              dismissToast(toastId);
              addToast(
                'success',
                'Instance Ready!',
                `${result.instanceId} has been created with blockchain data`,
                { duration: 10000 }
              );
              
              // Reload instances
              const instancesResponse = await authenticatedFetch(`${API_BASE_URL}/api/instances`);
              const instancesData = await instancesResponse.json();
              setInstances(instancesData.instances);
              setExtractingInstance(null);
            } else if (progress.status === 'error') {
              if (extractionProgressInterval.current) {
                clearInterval(extractionProgressInterval.current);
                extractionProgressInterval.current = null;
              }
              
              dismissToast(toastId);
              addToast(
                'warning',
                'Extraction Failed',
                `${result.instanceId} was created but blockchain extraction failed. Instance will sync from scratch.`,
                { duration: 15000 }
              );
              
              // Reload instances
              const instancesResponse = await authenticatedFetch(`${API_BASE_URL}/api/instances`);
              const instancesData = await instancesResponse.json();
              setInstances(instancesData.instances);
              setExtractingInstance(null);
            }
          } catch (pollError) {
            console.error('Failed to poll extraction progress:', pollError);
          }
        }, 3000); // Poll every 3 seconds
        
        return;
      }
      
      // Dismiss progress toast
      dismissToast(progressToastId);
      
      // Reload instances to show the new one
      const listResponse = await authenticatedFetch(`${API_BASE_URL}/api/instances`);
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
        authenticatedFetch(`${API_BASE_URL}/api/artifacts/github/import`, {
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
              const artifactsResponse = await authenticatedFetch(`${API_BASE_URL}/api/artifacts`);
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
              `${API_BASE_URL}/api/artifacts/import/progress/${data.releaseTag}`
            );
            
            console.log('Progress poll response status:', progressResponse.status);
            
            if (!progressResponse.ok) {
              // Import might be complete or not started yet
              if (progressResponse.status === 404) {
                // Check if artifact exists now (import complete)
                const artifactsResponse = await authenticatedFetch(`${API_BASE_URL}/api/artifacts`);
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
              const artifactsResponse = await authenticatedFetch(`${API_BASE_URL}/api/artifacts`);
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
        // File upload method - use chunked upload to avoid gateway timeouts
        setShowImportArtifactModal(false);
        
        const file = data.file;
        const tag = data.tag || 'unknown';
        const CHUNK_SIZE = 50 * 1024 * 1024; // 50MB chunks (good balance between reliability and efficiency)
        const totalChunks = Math.ceil(file.size / CHUNK_SIZE);
        const uploadId = `upload-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
        
        const progressToastId = addToast(
          'progress',
          'Uploading Artifact',
          `Uploading ${file.name} in ${totalChunks} chunks...`,
          { progress: 0 }
        );
        
        try {
          // Upload chunks sequentially
          for (let chunkIndex = 0; chunkIndex < totalChunks; chunkIndex++) {
            const start = chunkIndex * CHUNK_SIZE;
            const end = Math.min(start + CHUNK_SIZE, file.size);
            const chunk = file.slice(start, end);
            
            const formData = new FormData();
            formData.append('uploadId', uploadId);
            formData.append('tag', tag);
            formData.append('filename', file.name);
            formData.append('chunkIndex', chunkIndex.toString());
            formData.append('totalChunks', totalChunks.toString());
            formData.append('file', chunk, `chunk-${chunkIndex}`);
            
            const percentComplete = Math.round((chunkIndex / totalChunks) * 100);
            updateToast(progressToastId, {
              title: 'Uploading Artifact',
              message: `Uploading chunk ${chunkIndex + 1}/${totalChunks}`,
              progress: percentComplete,
            });
            
            const apiUrl = process.env.NEXT_PUBLIC_API_BASE || `${API_BASE_URL}`;
            const chunkResponse = await authenticatedFetch(`${apiUrl}/api/artifacts/import/chunk`, {
              method: 'POST',
              body: formData,
            });
            
            if (!chunkResponse.ok) {
              const errorData = await chunkResponse.json();
              throw new Error(errorData.message || 'Chunk upload failed');
            }
            
            await chunkResponse.json();
            
            // If this was the last chunk, server returns 202 and starts processing
            if (chunkResponse.status === 202) {
              console.log('All chunks uploaded, server is assembling and processing');
              
              // Switch toast to processing phase (keep same toast ID)
              updateToast(progressToastId, {
                title: 'Processing Artifact',
                message: 'Assembling uploaded file...',
                progress: undefined, // Switch to indeterminate for assembly/extraction
              });
              
              // Start polling for import progress
              const pollInterval = setInterval(async () => {
                try {
                  const progressResponse = await authenticatedFetch(
                    `${API_BASE_URL}/api/artifacts/import/progress/${tag}`
                  );
                  
                  if (!progressResponse.ok) {
                    console.error('Progress check failed:', progressResponse.status);
                    clearInterval(pollInterval);
                    dismissToast(progressToastId);
                    addToast('error', 'Import Failed', 'Failed to check import progress');
                    return;
                  }
                  
                  const progressData = await progressResponse.json();
                  console.log('Import progress:', progressData);
                  
                  updateToast(progressToastId, {
                    title: 'Processing Artifact',
                    message: progressData.message || `${progressData.status}...`,
                  });
                  
                  if (progressData.status === 'complete') {
                    clearInterval(pollInterval);
                    dismissToast(progressToastId);
                    
                    addToast(
                      'success',
                      'Import Complete',
                      `Artifact ${tag} imported successfully`,
                      { duration: 10000 }
                    );
                    
                    // Reload artifacts
                    const artifactsResponse = await authenticatedFetch(`${API_BASE_URL}/api/artifacts`);
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
                  } else if (progressData.status === 'error') {
                    clearInterval(pollInterval);
                    dismissToast(progressToastId);
                    
                    addToast(
                      'error',
                      'Import Failed',
                      progressData.error || 'Import failed',
                      { duration: 12000 }
                    );
                  }
                } catch (error) {
                  clearInterval(pollInterval);
                  dismissToast(progressToastId);
                  console.error('Failed to check import progress:', error);
                }
              }, 3000);
              
              return;
            }
          }
          
          // Shouldn't reach here, but handle just in case
          dismissToast(progressToastId);
          addToast('error', 'Upload Error', 'Unexpected response from server');
          
        } catch (error) {
          dismissToast(progressToastId);
          console.error('Upload error:', error);
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
      const response = await fetch(`${API_BASE_URL}/api/auth/login`, {
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
