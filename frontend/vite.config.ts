import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { fundApiPlugin } from './vite-plugins/fundApi.ts'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), fundApiPlugin()],
  define: {
    global: 'globalThis',
  },
})
