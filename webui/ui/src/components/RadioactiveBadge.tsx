/**
 * RadioactiveBadge Component
 * ===========================
 * SVG-based radioactive symbol with adjustable glow intensity.
 * Used to accent the war room aesthetic.
 * 
 * Props:
 *  - intensity: 0-4 (controls glow strength)
 *  - size: 'sm' | 'md' | 'lg'
 *  - className: additional CSS classes
 */

'use client';

import { cn } from '@/lib/utils';

interface RadioactiveBadgeProps {
  intensity?: 0 | 1 | 2 | 3 | 4;
  size?: 'sm' | 'md' | 'lg';
  className?: string;
}

export function RadioactiveBadge({
  intensity = 1,
  size = 'md',
  className,
}: RadioactiveBadgeProps) {
  const sizeMap = {
    sm: 16,
    md: 24,
    lg: 32,
  };
  
  const glowClass = `glow-${intensity}`;
  const dimension = sizeMap[size];
  
  return (
    <div
      className={cn('inline-flex items-center justify-center', glowClass, className)}
      role="img"
      aria-label="Radioactive symbol"
    >
      <svg
        width={dimension}
        height={dimension}
        viewBox="0 0 24 24"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
      >
        {/* SVG filter for additional glow effect */}
        <defs>
          <filter id={`glow-${intensity}`} x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur stdDeviation={intensity * 1.5} result="coloredBlur" />
            <feMerge>
              <feMergeNode in="coloredBlur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
        </defs>
        
        {/* Radioactive symbol: center circle + 3 blades */}
        <g filter={`url(#glow-${intensity})`}>
          {/* Center circle */}
          <circle
            cx="12"
            cy="12"
            r="2.5"
            fill="var(--acc-orange)"
            className="animate-pulse-glow"
          />
          
          {/* Blade 1 (top) */}
          <path
            d="M 12 9 L 9 3 A 9 9 0 0 1 15 3 L 12 9 Z"
            fill="var(--acc-orange)"
            opacity="0.8"
          />
          
          {/* Blade 2 (bottom-left) */}
          <path
            d="M 10.5 13.5 L 3 17 A 9 9 0 0 0 6 21 L 10.5 13.5 Z"
            fill="var(--acc-orange)"
            opacity="0.8"
          />
          
          {/* Blade 3 (bottom-right) */}
          <path
            d="M 13.5 13.5 L 18 21 A 9 9 0 0 0 21 17 L 13.5 13.5 Z"
            fill="var(--acc-orange)"
            opacity="0.8"
          />
        </g>
      </svg>
    </div>
  );
}
