// Comunicación con el backend: subida (POST /upload) y polling del resultado.

import { AppError } from "./errors.js";
import { debug } from "./settings.js";

const abortError = () => new DOMException("Cancelado", "AbortError");

/**
 * Sube el archivo en binario. Se usa XMLHttpRequest (y no fetch) para tener
 * progreso de subida. Resuelve con { id, kind }.
 */
export function uploadFile(url, file, { signal, onProgress } = {}) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(abortError());
      return;
    }

    const xhr = new XMLHttpRequest();
    xhr.open("POST", url);
    xhr.responseType = "json";
    // Informativo: el servidor decide el tipo por la firma del archivo.
    xhr.setRequestHeader("Content-Type", file.type || "application/octet-stream");

    xhr.upload.addEventListener("progress", (event) => {
      if (event.lengthComputable) onProgress?.(event.loaded / event.total);
    });

    xhr.addEventListener("load", () => {
      const body = xhr.response && typeof xhr.response === "object" ? xhr.response : {};
      if (xhr.status === 200 && typeof body.id === "string" && (body.kind === "image" || body.kind === "video")) {
        resolve({ id: body.id, kind: body.kind });
        return;
      }
      debug(`upload failed with status ${xhr.status}`);
      if (xhr.status === 400 && body.error) reject(new AppError(body.error));
      else if (xhr.status === 413) reject(new AppError("file_too_large"));
      else if (xhr.status === 429) reject(new AppError("throttled"));
      else reject(new AppError("internal_error"));
    });

    xhr.addEventListener("error", () => reject(new AppError("network_error")));
    xhr.addEventListener("abort", () => reject(abortError()));
    signal?.addEventListener("abort", () => xhr.abort(), { once: true });

    xhr.send(file);
  });
}

function sleep(ms, signal) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        reject(abortError());
      },
      { once: true },
    );
  });
}

/**
 * Consulta el JSON del resultado con retroceso (initialDelay → maxDelay) hasta
 * que exista o se agote el tiempo. Cualquier respuesta no OK (403/404 mientras
 * no existe) o error de red cuenta como "aún no".
 */
export async function pollResult(url, { signal, timeoutMs, initialDelayMs, maxDelayMs }) {
  const deadline = Date.now() + timeoutMs;
  let delay = initialDelayMs;

  while (Date.now() < deadline) {
    await sleep(delay, signal);
    try {
      const response = await fetch(url, { cache: "no-store", signal });
      if (response.ok) {
        const result = await response.json();
        if (result?.status === "SUCCEEDED" || result?.status === "FAILED") {
          return result;
        }
        throw new AppError("invalid_result");
      }
    } catch (error) {
      if (error.name === "AbortError" || error instanceof AppError) throw error;
      debug("poll attempt failed, retrying");
    }
    delay = Math.min(Math.round(delay * 1.5), maxDelayMs);
  }

  throw new AppError("timeout");
}
