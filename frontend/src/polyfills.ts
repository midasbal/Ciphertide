// @inco/lightning-js's encryption internals (hpke, mlkem) assume Node's
// Buffer global exists, which a browser does not provide by default. This
// must be imported before any other module that might reach into those
// internals (see index.html, loaded as the very first script), so the
// global exists the first time it is touched.
import { Buffer } from 'buffer'

const target = globalThis as unknown as { Buffer?: typeof Buffer }
if (typeof target.Buffer === 'undefined') {
  target.Buffer = Buffer
}
