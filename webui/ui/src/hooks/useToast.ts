/**
 * useToast Hook
 * =============
 * Manages toast notifications state and provides helper methods.
 */

'use client';

import { useState, useCallback } from 'react';
import type { Toast, ToastType } from '@/components/Toast';

let toastCounter = 0;

export function useToast() {
  const [toasts, setToasts] = useState<Toast[]>([]);

  const addToast = useCallback((
    type: ToastType,
    title: string,
    message?: string,
    options?: { duration?: number; progress?: number; showProgress?: boolean }
  ) => {
    const id = `toast-${++toastCounter}`;
    const toast: Toast = {
      id,
      type,
      title,
      message,
      progress: options?.progress,
      showProgress: options?.showProgress,
      duration: options?.duration ?? (type === 'progress' ? 0 : 5000), // Progress toasts don't auto-dismiss
    };
    
    setToasts(prev => [...prev, toast]);
    return id;
  }, []);

  const updateToast = useCallback((id: string, updates: Partial<Toast>) => {
    setToasts(prev => prev.map(toast => 
      toast.id === id ? { ...toast, ...updates } : toast
    ));
  }, []);

  const dismissToast = useCallback((id: string) => {
    setToasts(prev => prev.filter(toast => toast.id !== id));
  }, []);

  const clearAll = useCallback(() => {
    setToasts([]);
  }, []);

  return {
    toasts,
    addToast,
    updateToast,
    dismissToast,
    clearAll,
  };
}
