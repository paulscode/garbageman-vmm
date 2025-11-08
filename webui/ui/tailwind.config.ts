import type { Config } from 'tailwindcss'

/**
 * Tailwind Configuration - Garbageman WebUI
 * ==========================================
 * Extends default Tailwind theme with design tokens from tokens.css
 * 
 * Key customizations:
 *  - Dark war room color palette
 *  - Neon orange/green/amber accents
 *  - Glow box-shadow utilities
 *  - Motion tokens with reduced-motion support
 */

const config: Config = {
  darkMode: ['class'],
  content: [
    './src/pages/**/*.{js,ts,jsx,tsx,mdx}',
    './src/components/**/*.{js,ts,jsx,tsx,mdx}',
    './src/app/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  theme: {
    extend: {
      // =====================================================================
      // COLORS - Map CSS variables to Tailwind utilities
      // =====================================================================
      colors: {
        // Backgrounds
        bg0: 'var(--bg0)',
        bg1: 'var(--bg1)',
        bg2: 'var(--bg2)',
        bg3: 'var(--bg3)',
        
        // Text
        tx0: 'var(--tx0)',
        tx1: 'var(--tx1)',
        tx2: 'var(--tx2)',
        tx3: 'var(--tx3)',
        
        // Accents
        accent: {
          DEFAULT: 'var(--acc-orange)',
          bright: 'var(--acc-orange-bright)',
          dim: 'var(--acc-orange-dim)',
        },
        
        amber: {
          DEFAULT: 'var(--acc-amber)',
          bright: 'var(--acc-amber-bright)',
          dim: 'var(--acc-amber-dim)',
        },
        
        green: {
          DEFAULT: 'var(--acc-green)',
          bright: 'var(--acc-green-bright)',
          dim: 'var(--acc-green-dim)',
        },
        
        red: {
          DEFAULT: 'var(--acc-red)',
          bright: 'var(--acc-red-bright)',
          dim: 'var(--acc-red-dim)',
        },
        
        // Semantic aliases
        border: 'rgba(255, 107, 53, 0.2)',
        'border-bright': 'rgba(255, 107, 53, 0.6)',
        'border-subtle': 'rgba(255, 255, 255, 0.1)',
      },
      
      // =====================================================================
      // BOX SHADOWS - Glow effects
      // =====================================================================
      boxShadow: {
        'glow-0': 'var(--g0)',
        'glow-1': 'var(--g1)',
        'glow-2': 'var(--g2)',
        'glow-3': 'var(--g3)',
        'glow-4': 'var(--g4)',
        'glow-green-1': 'var(--g-green-1)',
        'glow-green-2': 'var(--g-green-2)',
        'glow-green-3': 'var(--g-green-3)',
        'glow-amber-1': 'var(--g-amber-1)',
        'glow-amber-2': 'var(--g-amber-2)',
      },
      
      // =====================================================================
      // BORDER RADIUS
      // =====================================================================
      borderRadius: {
        sm: 'var(--radius-sm)',
        md: 'var(--radius-md)',
        lg: 'var(--radius-lg)',
        full: 'var(--radius-full)',
      },
      
      // =====================================================================
      // FONT FAMILIES
      // =====================================================================
      fontFamily: {
        sans: ['var(--font-sans)'],
        mono: ['var(--font-mono)'],
      },
      
      // =====================================================================
      // ANIMATION & TRANSITIONS
      // =====================================================================
      transitionDuration: {
        instant: 'var(--duration-instant)',
        fast: 'var(--duration-fast)',
        normal: 'var(--duration-normal)',
        slow: 'var(--duration-slow)',
        slower: 'var(--duration-slower)',
      },
      
      transitionTimingFunction: {
        'in': 'var(--ease-in)',
        'out': 'var(--ease-out)',
        'in-out': 'var(--ease-in-out)',
        'bounce': 'var(--ease-bounce)',
      },
      
      animation: {
        'pulse-glow': 'pulse-glow 2s ease-in-out infinite',
        'scan-in': 'scan-in 0.6s var(--ease-out) forwards',
        'slide-in-down': 'slide-in-down 0.3s var(--ease-out) forwards',
      },
      
      keyframes: {
        'pulse-glow': {
          '0%, 100%': { boxShadow: 'var(--g1)' },
          '50%': { boxShadow: 'var(--g3)' },
        },
        'scan-in': {
          '0%': {
            opacity: '0',
            transform: 'translateY(20px) scaleY(0.95)',
          },
          '100%': {
            opacity: '1',
            transform: 'translateY(0) scaleY(1)',
          },
        },
        'slide-in-down': {
          '0%': {
            opacity: '0',
            transform: 'translateY(-20px)',
          },
          '100%': {
            opacity: '1',
            transform: 'translateY(0)',
          },
        },
      },
    },
  },
  plugins: [],
}

export default config
