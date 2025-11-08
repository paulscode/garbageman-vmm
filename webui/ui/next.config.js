/** @type {import('next').NextConfig} */
const nextConfig = {
  // API proxy during development
  async rewrites() {
    return [
      {
        source: '/api/:path*',
        // Use API_BASE_URL for server-side (container-to-container)
        // or fall back to NEXT_PUBLIC_API_BASE for browser-side
        destination: process.env.API_BASE_URL 
          ? `${process.env.API_BASE_URL}/api/:path*`
          : process.env.NEXT_PUBLIC_API_BASE 
            ? `${process.env.NEXT_PUBLIC_API_BASE}/api/:path*`
            : 'http://localhost:8080/api/:path*',
      },
    ]
  },
  
  // Strict mode for development
  reactStrictMode: true,
  
  // Optimize fonts
  optimizeFonts: true,
  
  // Enable standalone output for Docker
  output: 'standalone',
}

export default nextConfig
