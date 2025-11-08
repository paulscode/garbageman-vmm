/**
 * Toast Component
 * ===============
 * Theme-styled notification system for displaying messages at the top of the page.
 * 
 * Features:
 *  - Auto-dismiss after duration
 *  - Multiple toast types: info, success, error, warning, progress
 *  - Animated entrance/exit
 *  - Progress bar for long-running operations
 */

'use client';

import { useEffect } from 'react';
import { cn } from '@/lib/utils';

export type ToastType = 'info' | 'success' | 'error' | 'warning' | 'progress';

export interface Toast {
  id: string;
  type: ToastType;
  title: string;
  message?: string;
  progress?: number; // 0-100 for progress type
  showProgress?: boolean; // Show indeterminate progress bar
  duration?: number; // Auto-dismiss duration in ms (0 = no auto-dismiss)
}

interface ToastItemProps {
  toast: Toast;
  onDismiss: (id: string) => void;
}

export function ToastItem({ toast, onDismiss }: ToastItemProps) {
  useEffect(() => {
    if (toast.duration && toast.duration > 0 && toast.type !== 'progress') {
      const timer = setTimeout(() => {
        onDismiss(toast.id);
      }, toast.duration);
      
      return () => clearTimeout(timer);
    }
  }, [toast.id, toast.duration, toast.type, onDismiss]);

  const typeStyles = {
    info: 'border-acc-blue bg-acc-blue/10',
    success: 'border-acc-green bg-acc-green/10',
    error: 'border-acc-red bg-acc-red/10',
    warning: 'border-amber-500 bg-amber-500/10',
    progress: 'border-acc-orange bg-acc-orange/10',
  };

  const typeIcons = {
    info: 'ℹ️',
    success: '✅',
    error: '❌',
    warning: '⚠️',
    progress: '⏳',
  };

  return (
    <div
      className={cn(
        'min-w-[320px] max-w-md p-4 border-4 rounded font-mono shadow-lg',
        'animate-slide-in-down backdrop-blur-sm',
        typeStyles[toast.type]
      )}
    >
      <div className="flex items-start gap-3">
        <div className="text-2xl">{typeIcons[toast.type]}</div>
        <div className="flex-1 min-w-0">
          <div className="font-bold text-tx0 text-sm mb-1">
            {toast.title}
          </div>
          {toast.message && (
            <div className="text-xs text-tx2 break-words">
              {toast.message}
            </div>
          )}
          {toast.type === 'progress' && typeof toast.progress === 'number' && (
            <div className="mt-2">
              <div className="h-2 bg-bg3 rounded-full overflow-hidden">
                <div
                  className="h-full bg-accent transition-all duration-300"
                  style={{ width: `${Math.min(100, Math.max(0, toast.progress))}%` }}
                />
              </div>
              <div className="text-xs text-tx3 mt-1 text-right">
                {Math.round(toast.progress)}%
              </div>
            </div>
          )}
          {toast.type === 'progress' && toast.showProgress && typeof toast.progress !== 'number' && (
            <div className="mt-2">
              <div className="h-2 bg-bg3 rounded-full overflow-hidden">
                <div className="h-full w-full bg-accent animate-pulse" />
              </div>
            </div>
          )}
          {toast.showProgress && toast.type !== 'progress' && (
            <div className="mt-2">
              <div className="h-2 bg-bg3 rounded-full overflow-hidden">
                <div className="h-full w-full bg-accent animate-pulse" />
              </div>
            </div>
          )}
        </div>
        <button
          onClick={() => onDismiss(toast.id)}
          className="text-tx3 hover:text-tx0 transition-colors text-lg leading-none"
        >
          ×
        </button>
      </div>
    </div>
  );
}

interface ToastContainerProps {
  toasts: Toast[];
  onDismiss: (id: string) => void;
}

export function ToastContainer({ toasts, onDismiss }: ToastContainerProps) {
  if (toasts.length === 0) return null;

  return (
    <div className="fixed top-4 right-4 z-[9999] space-y-3 pointer-events-none">
      {toasts.map((toast) => (
        <div key={toast.id} className="pointer-events-auto">
          <ToastItem toast={toast} onDismiss={onDismiss} />
        </div>
      ))}
    </div>
  );
}
