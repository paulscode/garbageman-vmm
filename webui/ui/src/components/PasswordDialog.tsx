/**
 * PasswordDialog Component
 * ========================
 * Full-screen password authentication overlay.
 * 
 * Features:
 *  - Must be cleared before accessing the application
 *  - Password controlled by wrapper config (no management UI)
 *  - Clean, focused input with war room aesthetic
 *  - Shows error on incorrect password
 *  - No way to bypass or close without correct password
 */

'use client';

import { useState, useEffect, useRef } from 'react';
import { cn } from '@/lib/utils';

interface PasswordDialogProps {
  isLocked: boolean;
  onUnlock: (password: string) => void;
}

export function PasswordDialog({ isLocked, onUnlock }: PasswordDialogProps) {
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [isShaking, setIsShaking] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  // Auto-focus input when dialog appears
  useEffect(() => {
    if (isLocked && inputRef.current) {
      inputRef.current.focus();
    }
  }, [isLocked]);

  // Trigger shake on external error (from parent validation)
  useEffect(() => {
    if (error) {
      triggerShake();
      setPassword('');
      // Clear error after delay
      const timer = setTimeout(() => setError(''), 2000);
      return () => clearTimeout(timer);
    }
  }, [error]);

  if (!isLocked) return null;

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    
    if (!password.trim()) {
      setError('Password required');
      triggerShake();
      return;
    }

    // Call the unlock handler - parent will validate
    onUnlock(password);
  };

  const triggerShake = () => {
    setIsShaking(true);
    setTimeout(() => setIsShaking(false), 500);
  };

  return (
    <div className="fixed inset-0 z-[100] flex items-center justify-center bg-bg0 scanlines noise-texture">
      {/* Radioactive Watermark Background */}
      <div className="absolute inset-0 flex items-center justify-center pointer-events-none opacity-5">
        <div className="text-[600px] leading-none select-none">☢</div>
      </div>

      {/* Password Input Card */}
      <div className="relative z-10 w-full max-w-md mx-4">
        <div 
          className={cn(
            "card border-bright p-8 transition-transform duration-200",
            isShaking && "animate-shake"
          )}
        >
          {/* Header */}
          <div className="text-center mb-8">
            <div className="text-6xl mb-4">🔒</div>
            <h1 className="text-3xl font-bold font-mono text-tx0 glow-1 uppercase mb-2">
              SECURE ACCESS
            </h1>
            <p className="text-sm text-tx3 font-mono">
              Authentication required to access Garbageman Node Manager
            </p>
          </div>

          {/* Password Form */}
          <form onSubmit={handleSubmit} className="space-y-6">
            <div>
              <label className="block text-xs text-tx3 uppercase font-mono mb-2">
                Password
              </label>
              <input
                ref={inputRef}
                type="password"
                value={password}
                onChange={(e) => {
                  setPassword(e.target.value);
                  setError(''); // Clear error on input
                }}
                placeholder="Enter password..."
                className={cn(
                  "w-full px-4 py-4 bg-bg2 border-4 rounded font-mono text-tx0 text-lg",
                  "placeholder-tx3 focus:outline-none transition-all",
                  error
                    ? "border-red-500 focus:border-red-500"
                    : "border-subtle focus:border-acc-orange focus:glow-2"
                )}
                autoComplete="off"
                spellCheck={false}
              />
              {error && (
                <p className="text-red-500 text-sm font-mono mt-2 font-bold">
                  ⚠ {error}
                </p>
              )}
            </div>

            <button
              type="submit"
              className={cn(
                "w-full px-6 py-4 font-mono font-bold rounded transition-all border-4 text-lg uppercase",
                password.trim()
                  ? "bg-acc-orange/10 text-tx0 border-acc-orange hover:border-tx0 hover:bg-acc-orange/20 shadow-lg glow-2"
                  : "bg-bg2 text-tx3 border-bg3 cursor-not-allowed opacity-50"
              )}
              disabled={!password.trim()}
            >
              🔓 UNLOCK
            </button>
          </form>

          {/* Footer */}
          <div className="mt-6 pt-6 border-t border-subtle">
            <p className="text-xs text-tx3 font-mono text-center">
              Password managed via wrapper configuration
            </p>
          </div>
        </div>
      </div>

      {/* Add shake animation styles */}
      <style jsx>{`
        @keyframes shake {
          0%, 100% { transform: translateX(0); }
          10%, 30%, 50%, 70%, 90% { transform: translateX(-10px); }
          20%, 40%, 60%, 80% { transform: translateX(10px); }
        }
        .animate-shake {
          animation: shake 0.5s ease-in-out;
        }
      `}</style>
    </div>
  );
}
