import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

declare const process: { env: Record<string, string | undefined> };

// `npm run dev` serves the UI with hot reload and proxies the API to a running Proxmacs
// (PROXMACS_URL, default https://127.0.0.1:8006; its self-signed certificate is accepted).
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    chunkSizeWarningLimit: 1024,
  },
  server: {
    proxy: {
      '/api': {
        target: process.env.PROXMACS_URL ?? 'https://127.0.0.1:8006',
        secure: false,
        ws: true,
      },
    },
  },
});
