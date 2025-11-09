/**
 * API Configuration
 * 
 * Provides the base URL for API requests.
 * In production (StartOS/Docker), uses relative paths so Next.js rewrites handle proxying.
 * In development, can use localhost or environment variable override.
 */

export const getApiBaseUrl = (): string => {
  // In browser, always use relative path (empty string)
  // This allows Next.js rewrites to proxy to the API server
  if (typeof window !== 'undefined') {
    return '';
  }
  
  // Server-side: use environment variable or default
  return process.env.API_BASE_URL || 'http://localhost:8080';
};

export const API_BASE_URL = getApiBaseUrl();
