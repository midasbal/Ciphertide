import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { fundApiPlugin } from './vite-plugins/fundApi'
import { chatApiPlugin } from './vite-plugins/chatApi'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), fundApiPlugin(), chatApiPlugin()],
  define: {
    global: 'globalThis',
  },
})
