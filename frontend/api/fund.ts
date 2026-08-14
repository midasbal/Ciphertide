// Serverless entry point for the sponsor funding endpoint, for whenever
// this app is deployed to a real host. Not deployed anywhere yet, the
// host (Vercel, Cloudflare, a plain Node server, and so on) is not
// decided, so this only re-exports the portable core handler as a
// standard Fetch API Request -> Response function, the shape most
// serverless platforms accept directly or need only a thin adapter for.
// During local dev this same core handler is wired into the Vite dev
// server instead, see vite-plugins/fundApi.ts, so both paths run the
// exact same logic and cannot drift apart.
export { handleFundRequest as default } from '../server/fundHandler.ts'
