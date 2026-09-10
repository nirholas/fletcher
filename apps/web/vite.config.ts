import { defineConfig } from "vite";

export default defineConfig({
  server: { port: 5273 },
  build: { target: "es2022" },
});
