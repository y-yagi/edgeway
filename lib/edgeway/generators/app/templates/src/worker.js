import app from "../build/app.wasm";
import { createWorker } from "../build/edgeway/cloudflare.js";

export default createWorker(app);
