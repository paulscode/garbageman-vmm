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
      aria-label="Nuclear symbol"
    >
      <svg
        width={dimension}
        height={dimension}
        viewBox="0 0 122.88 122.88"
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
        
        {/* Nuclear symbol from download2.svg */}
        <g filter={`url(#glow-${intensity})`}>
          {/* Outer circle */}
          <path 
            d="M61.44,0A61.46,61.46,0,1,1,18,18,61.21,61.21,0,0,1,61.44,0Z" 
            fill="var(--acc-orange)"
            className="animate-pulse-glow"
          />
          {/* Inner circle */}
          <path 
            d="M61.44,6.67A54.77,54.77,0,1,1,6.67,61.44,54.77,54.77,0,0,1,61.44,6.67Z" 
            fill="var(--bg0)"
          />
          {/* Center dot */}
          <path 
            d="M61.5,53.07a8.95,8.95,0,1,1-9,8.94,8.95,8.95,0,0,1,9-8.94Z" 
            fill="var(--acc-orange)"
          />
          {/* Left blade */}
          <path 
            d="M15.17,61.89C16,44.64,23.59,31.13,38.4,21.68L54.68,50.34c-3.85,2.16-6.09,6-6.68,11.55Z" 
            fill="var(--acc-orange)"
          />
          {/* Top-right blade */}
          <path 
            d="M84.63,21.46c14.5,9.38,22.42,22.67,23.2,40.23l-33-.24c0-4.41-2.15-8.27-6.66-11.55L84.63,21.46Z" 
            fill="var(--acc-orange)"
          />
          {/* Bottom blade */}
          <path 
            d="M84.87,101.71c-15.36,7.88-30.84,8.09-46.43,0L55.12,73.27c3.79,2.25,8.24,2.27,13.3,0l16.45,28.44Z" 
            fill="var(--acc-orange)"
          />
        </g>
      </svg>
    </div>
  );
}
