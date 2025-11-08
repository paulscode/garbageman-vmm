import type { Metadata } from 'next'
import { Inter } from 'next/font/google'
import '@/styles/globals.css'

/**
 * Root Layout - Garbageman WebUI
 * ================================
 * Sets up fonts, global styles, and page structure.
 * Dark war room aesthetic with neon accents.
 */

const inter = Inter({ subsets: ['latin'], variable: '--font-sans' })

export const metadata: Metadata = {
  title: 'Garbageman Nodes Manager',
  description: 'WebUI for managing multiple Bitcoin daemon instances',
  keywords: ['bitcoin', 'garbageman', 'knots', 'daemon', 'nodes'],
  icons: {
    icon: '/favicon.svg',
  },
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="en" className="dark">
      <head>
        <link rel="icon" type="image/svg+xml" href="/favicon.svg" />
      </head>
      <body className={`${inter.variable} antialiased bg-bg0 text-tx1`}>
        {children}
      </body>
    </html>
  )
}
