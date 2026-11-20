// Formato de números y tiempos para la interfaz (es-ES).

const oneDecimal = new Intl.NumberFormat("es-ES", { minimumFractionDigits: 1, maximumFractionDigits: 1 });
const upToOneDecimal = new Intl.NumberFormat("es-ES", { maximumFractionDigits: 1 });

/** 98.4 → "98,4 %" */
export const percent = (value) => `${oneDecimal.format(value)} %`;

/** 1834 → "1,8 s" */
export const seconds = (ms) => `${oneDecimal.format(ms / 1000)} s`;

/** 75 → "75 %" (umbral configurado, sin decimales forzados) */
export const threshold = (value) => `${upToOneDecimal.format(value)} %`;

/** 4194304 → "4 MB", 51200 → "50 KB" (base 1024, como el límite del servidor) */
export function megabytes(bytes) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${upToOneDecimal.format(bytes / (1024 * 1024))} MB`;
}

/** 65000 → "1:05" */
export function clock(ms) {
  const total = Math.max(0, Math.round(ms / 1000));
  const minutes = Math.floor(total / 60);
  const secs = total % 60;
  return `${minutes}:${String(secs).padStart(2, "0")}`;
}

/** (3, "etiqueta", "etiquetas") → "3 etiquetas" */
export const plural = (count, one, many) => `${count} ${count === 1 ? one : many}`;
