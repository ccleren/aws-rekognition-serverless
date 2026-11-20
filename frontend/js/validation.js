// Validación en el cliente: misma regla que la Lambda Upload (firma del archivo
// y tamaño) para avisar antes de subir. El servidor sigue siendo la autoridad.

import { megabytes } from "./format.js";

const JPEG = [0xff, 0xd8, 0xff];
const PNG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
// Imágenes HEIF/AVIF también usan la caja "ftyp"; no son vídeo.
const NON_VIDEO_BRANDS = new Set(["heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs", "mif1", "msf1", "avif", "avis", "crx "]);

export class ValidationError extends Error {
  constructor(message) {
    super(message);
    this.name = "ValidationError";
  }
}

const startsWith = (bytes, signature) => signature.every((value, index) => bytes[index] === value);
const ascii = (bytes, start, end) => String.fromCharCode(...bytes.slice(start, end));

/** Devuelve { kind, format } según los primeros bytes, o null si no es JPEG, PNG ni MP4. */
export function detectKind(bytes) {
  if (startsWith(bytes, JPEG)) return { kind: "image", format: "JPEG" };
  if (startsWith(bytes, PNG)) return { kind: "image", format: "PNG" };
  if (bytes.length >= 12 && ascii(bytes, 4, 8) === "ftyp" && !NON_VIDEO_BRANDS.has(ascii(bytes, 8, 12))) {
    return { kind: "video", format: "MP4" };
  }
  return null;
}

export async function validateFile(file, maxBytes) {
  if (!file || file.size === 0) {
    throw new ValidationError("El archivo está vacío.");
  }
  if (file.size > maxBytes) {
    throw new ValidationError(`El archivo pesa ${megabytes(file.size)} y el máximo es ${megabytes(maxBytes)}.`);
  }

  const header = new Uint8Array(await file.slice(0, 12).arrayBuffer());
  const detected = detectKind(header);
  if (!detected) {
    throw new ValidationError("Formato no admitido. Usa una imagen JPG o PNG, o un vídeo MP4 (H.264).");
  }
  return detected;
}
