// Configuración en tiempo de ejecución. window.APP_CONFIG lo define config.js,
// que genera Terraform con los endpoints reales (no se versiona).

const raw = window.APP_CONFIG ?? {};

const REQUIRED_KEYS = ["API_URL", "RESULTS_BASE_URL", "MAX_UPLOAD_BYTES"];

const number = (value, fallback) => (Number.isFinite(Number(value)) && Number(value) > 0 ? Number(value) : fallback);
const withoutTrailingSlash = (url) => String(url ?? "").replace(/\/+$/, "");

export const configOk = REQUIRED_KEYS.every((key) => Boolean(raw[key]));

export const settings = Object.freeze({
  // El nombre visible solo se define en Terraform (variable app_name).
  appName: raw.APP_NAME || "Análisis de imágenes",
  apiUrl: withoutTrailingSlash(raw.API_URL),
  resultsBaseUrl: withoutTrailingSlash(raw.RESULTS_BASE_URL),
  maxUploadBytes: number(raw.MAX_UPLOAD_BYTES, 4 * 1024 * 1024),
  minConfidence: number(raw.MIN_CONFIDENCE, null),
  pollInitialDelayMs: number(raw.POLL_INITIAL_DELAY_MS, 1000),
  pollMaxDelayMs: number(raw.POLL_MAX_DELAY_MS, 4000),
  pollImageTimeoutMs: number(raw.POLL_IMAGE_TIMEOUT_MS, 60_000),
  pollVideoTimeoutMs: number(raw.POLL_VIDEO_TIMEOUT_MS, 360_000),
  retentionHours: number(raw.DATA_RETENTION_HOURS, 24),
  // Desactivado por defecto. Solo registra nombres de eventos, nunca datos.
  debug: raw.DEBUG === true,
});

export function debug(event) {
  if (settings.debug) {
    console.debug(`[app] ${event}`);
  }
}
