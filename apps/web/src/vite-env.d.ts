/// <reference types="vite/client" />

/**
 * The deployment the app points at, supplied at build time. Typed explicitly so a missing or
 * misspelled variable is a compile error rather than an `undefined` that reaches a contract call.
 */
interface ImportMetaEnv {
  readonly VITE_FLETCHER_FACTORY?: string;
  readonly VITE_FLETCHER_LAUNCHPAD?: string;
  readonly VITE_FLETCHER_SETTLEMENT_SOURCE?: string;
  readonly VITE_FLETCHER_ACCOUNTANT?: string;
  readonly VITE_FLETCHER_DEPTH_GATE?: string;
  readonly VITE_RHC_RPC_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
