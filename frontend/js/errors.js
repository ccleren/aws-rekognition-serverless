// Códigos de error del contrato JSON (API y resultados) y del propio cliente,
// con el texto que se muestra al usuario.

export class AppError extends Error {
  constructor(code, { message } = {}) {
    super(message ?? code);
    this.name = "AppError";
    this.code = code;
  }
}

const MESSAGES = {
  // Respuestas 400 de POST /upload
  empty_body: {
    message: "El archivo está vacío.",
    help: "Elige otro archivo.",
  },
  file_too_large: {
    message: "El archivo supera el tamaño máximo permitido.",
    help: "Reduce su tamaño (o la duración del vídeo) y vuelve a intentarlo.",
  },
  unsupported_type: {
    message: "El formato del archivo no es compatible.",
    help: "Se admiten imágenes JPG y PNG y vídeos MP4 con códec H.264. El tipo se comprueba por el contenido, no por la extensión.",
  },
  // Subida
  throttled: {
    message: "Hay demasiadas peticiones en este momento.",
    help: "Espera unos segundos y vuelve a intentarlo.",
  },
  network_error: {
    message: "No se pudo conectar con el servidor.",
    help: "Comprueba tu conexión y vuelve a intentarlo.",
  },
  internal_error: {
    message: "No se pudo subir el archivo.",
    help: "Ha fallado algo en el servidor. Vuelve a intentarlo en unos minutos.",
  },
  // Resultados FAILED
  processing_failed: {
    message: "No se pudo analizar el archivo.",
    help: "Puede que el archivo esté dañado o que Rekognition no pueda leerlo. Prueba con otro.",
  },
  unsupported_video_codec: {
    message: "El vídeo no usa el códec H.264.",
    help: "Rekognition Video solo admite vídeo H.264 en MP4 (muchos móviles graban en HEVC). Conviértelo, por ejemplo: ffmpeg -i entrada.mov -c:v libx264 -an salida.mp4",
  },
  analysis_failed: {
    message: "Rekognition no pudo completar el análisis del vídeo.",
    help: "Vuelve a intentarlo o prueba con otro vídeo.",
  },
  // Cliente
  timeout: {
    message: "El análisis está tardando más de lo esperado.",
    help: "Puede que el servicio esté ocupado. Vuelve a intentarlo más tarde.",
  },
  invalid_result: {
    message: "El resultado recibido no tiene el formato esperado.",
    help: "Vuelve a intentarlo.",
  },
};

export function describeError(error) {
  const code = error instanceof AppError ? error.code : "internal_error";
  return MESSAGES[code] ?? MESSAGES.internal_error;
}
