// Punto de entrada. Estados: reposo → subiendo → analizando → resultado | error.

import { pollResult, uploadFile } from "./api.js";
import { $, icon } from "./dom.js";
import { AppError, describeError } from "./errors.js";
import { clock, megabytes, plural, seconds, threshold } from "./format.js";
import { renderImageResult } from "./image-view.js";
import { configOk, debug, settings } from "./settings.js";
import { initTheme } from "./theme.js";
import { validateFile, ValidationError } from "./validation.js";
import { renderVideoResult } from "./video-view.js";

const ui = {
  announcer: $("announcer"),
  configError: $("config-error"),
  idle: $("view-idle"),
  work: $("view-work"),
  dropzone: $("dropzone"),
  fileInput: $("file-input"),
  fileError: $("file-error"),
  statusIcon: $("status-icon"),
  statusTitle: $("status-title"),
  statusMeta: $("status-meta"),
  cancelButton: $("cancel-button"),
  resumeButton: $("resume-button"),
  resetButton: $("reset-button"),
  exportButton: $("export-button"),
  imageStage: $("image-stage"),
  image: $("preview-image"),
  boxes: $("boxes"),
  videoStage: $("video-stage"),
  video: $("preview-video"),
  timeline: {
    root: $("timeline"),
    range: $("timeline-range"),
    progress: $("timeline-progress"),
    marker: $("timeline-marker"),
    ticks: $("timeline-ticks"),
  },
  previewHint: $("preview-hint"),
  boxLegend: $("box-legend"),
  progressPanel: $("progress-panel"),
  uploadBar: $("upload-bar-fill"),
  steps: {
    upload: { item: $("step-upload"), detail: $("step-upload-detail") },
    analyze: { item: $("step-analyze"), detail: $("step-analyze-detail") },
    result: { item: $("step-result"), detail: $("step-result-detail") },
  },
  labelsPanel: $("labels-panel"),
  labelsOrder: $("labels-order"),
  labelList: $("label-list"),
  labelsEmpty: $("labels-empty"),
  labelsNote: $("labels-note"),
  errorPanel: $("error-panel"),
  errorTitle: $("error-title"),
  errorMessage: $("error-message"),
  errorHelp: $("error-help"),
};

/** Estado del análisis en curso. Se reinicia en cada archivo. */
let job = null;

// --- Utilidades de interfaz ------------------------------------------------------

function announce(message) {
  // Vaciar antes de escribir fuerza la lectura aunque el texto se repita.
  ui.announcer.textContent = "";
  requestAnimationFrame(() => {
    ui.announcer.textContent = message;
  });
}

function setStatus({ tone, title, meta }) {
  ui.statusIcon.className = "status-icon";
  ui.statusIcon.replaceChildren();
  if (tone === "busy") ui.statusIcon.classList.add("is-busy");
  if (tone === "error") {
    ui.statusIcon.classList.add("is-error");
    ui.statusIcon.append(icon("alert"));
  }
  if (tone === "done") ui.statusIcon.append(icon("check"));
  if (tone === "waiting") ui.statusIcon.append(icon("clock"));
  ui.statusTitle.textContent = title;
  ui.statusMeta.textContent = meta ?? "";
}

function setStep(name, state, detail) {
  const step = ui.steps[name];
  step.item.classList.toggle("is-active", state === "active");
  step.item.classList.toggle("is-done", state === "done");
  step.item.classList.toggle("is-failed", state === "failed");
  if (detail !== undefined) step.detail.textContent = detail;
}

function showFileError(message) {
  ui.fileError.textContent = message;
  ui.fileError.hidden = false;
}

function setActions({ cancel = false, resume = false, reset = false, exportPdf = false }) {
  ui.cancelButton.hidden = !cancel;
  ui.resumeButton.hidden = !resume;
  ui.resetButton.hidden = !reset;
  ui.exportButton.hidden = !exportPdf;
}

// --- Flujo ------------------------------------------------------------------------

async function handleFile(file) {
  if (!file || job) return;
  ui.fileError.hidden = true;

  let detected;
  try {
    detected = await validateFile(file, settings.maxUploadBytes);
  } catch (error) {
    const message = error instanceof ValidationError ? error.message : "No se pudo leer el archivo.";
    showFileError(message);
    return;
  }

  await analyze(file, detected);
}

async function analyze(file, detected) {
  job = {
    file,
    format: detected.format,
    kind: detected.kind,
    controller: new AbortController(),
    objectUrl: URL.createObjectURL(file),
    startedAt: performance.now(),
    analysisStartedAt: null,
    resultUrl: null,
    fileMeta: `${file.name} · ${megabytes(file.size)}`,
    ticker: null,
    view: null,
    result: null,
  };

  showWorkView();
  showPreview();
  setStatus({ tone: "busy", title: "Subiendo archivo…", meta: job.fileMeta });
  setActions({ cancel: true });
  setStep("upload", "active", "Enviando… 0 %");
  setStep("analyze", "pending", "En espera");
  setStep("result", "pending", "En espera");
  announce(`Subiendo ${file.name}`);
  ui.statusTitle.focus();

  try {
    const { id, kind } = await uploadFile(`${settings.apiUrl}/upload`, file, {
      signal: job.controller.signal,
      onProgress: (fraction) => {
        const value = Math.round(fraction * 100);
        ui.uploadBar.style.width = `${value}%`;
        setStep("upload", "active", value < 100 ? `Enviando… ${value} %` : "Validando en el servidor…");
      },
    });
    job.kind = kind;
    job.resultUrl = `${settings.resultsBaseUrl}/${kind === "video" ? "output-video" : "output"}/${id}.json`;
    job.analysisStartedAt = performance.now();
    debug("upload accepted");
  } catch (error) {
    if (error?.name === "AbortError") return;
    showError(error, "upload");
    return;
  }

  ui.uploadBar.style.width = "100%";
  setStep("upload", "done", `Completada (${megabytes(file.size)})`);
  announce("Archivo subido. Analizando.");
  await waitForResult();
}

/**
 * Consulta el resultado hasta que exista. Si se agota el tiempo, el análisis
 * puede seguir en marcha (la cola de Rekognition Video tarda varios minutos):
 * se ofrece seguir esperando el mismo resultado en vez de darlo por fallido.
 */
async function waitForResult() {
  if (!job || job.polling) return; // nunca dos consultas en paralelo del mismo análisis
  const current = job;
  current.polling = true;
  try {
    await pollUntilDone(current);
  } finally {
    current.polling = false;
  }
}

async function pollUntilDone(current) {
  const { kind } = current;
  setStatus({ tone: "busy", title: "Analizando con Rekognition…", meta: current.fileMeta });
  setActions({ cancel: true });
  ui.progressPanel.hidden = false;
  ui.errorPanel.hidden = true;
  startTicker(kind);

  try {
    const result = await pollResult(current.resultUrl, {
      signal: current.controller.signal,
      timeoutMs: kind === "video" ? settings.pollVideoTimeoutMs : settings.pollImageTimeoutMs,
      initialDelayMs: settings.pollInitialDelayMs,
      maxDelayMs: settings.pollMaxDelayMs,
    });
    stopTicker();

    if (result.status === "FAILED") throw new AppError(result.error || "processing_failed");
    if (!Array.isArray(result.labels) || result.kind !== kind) throw new AppError("invalid_result");

    showResult(result, performance.now() - current.startedAt);
  } catch (error) {
    stopTicker();
    if (error?.name === "AbortError") return;
    if (error instanceof AppError && error.code === "timeout") {
      showStillRunning();
      return;
    }
    showError(error, "analyze");
  }
}

function startTicker(kind) {
  const message =
    kind === "video" ? "Rekognition Video procesa el vídeo; puede tardar unos minutos" : "Detectando etiquetas";
  const tick = () => setStep("analyze", "active", `${message} · ${clock(performance.now() - job.analysisStartedAt)}`);
  tick();
  job.ticker = setInterval(tick, 1000);
}

function stopTicker() {
  if (job?.ticker) clearInterval(job.ticker);
  if (job) job.ticker = null;
}

// --- Vistas -------------------------------------------------------------------------

function showWorkView() {
  ui.idle.hidden = true;
  ui.work.hidden = false;
  ui.progressPanel.hidden = false;
  ui.labelsPanel.hidden = true;
  ui.errorPanel.hidden = true;
  ui.uploadBar.style.width = "0%";
  ui.boxLegend.hidden = true;
  ui.previewHint.textContent = "";
}

function showPreview() {
  const isVideo = job.kind === "video";
  ui.imageStage.hidden = isVideo;
  ui.videoStage.hidden = !isVideo;
  ui.timeline.root.hidden = true;
  if (isVideo) {
    ui.video.src = job.objectUrl;
  } else {
    ui.image.src = job.objectUrl;
    ui.image.alt = `Vista previa de ${job.file.name}`;
  }
}

function showResult(result, analysisMs) {
  job.result = result;
  job.analysisMs = analysisMs;
  const isVideo = result.kind === "video";
  const count = result.labels.length;

  setStep("analyze", "done", `Completado en ${seconds(analysisMs)}`);
  setStep("result", "done", "Listo");
  ui.progressPanel.hidden = true;
  ui.labelsPanel.hidden = false;
  ui.labelsEmpty.hidden = count > 0;
  ui.labelsEmpty.textContent = `Rekognition no ha detectado etiquetas${settings.minConfidence ? ` con confianza igual o superior al ${threshold(settings.minConfidence)}` : ""}.`;
  ui.labelsOrder.textContent = isVideo ? "por primera aparición" : "ordenadas por confianza";
  ui.labelsNote.hidden = !isVideo || count === 0;

  const meta = [plural(count, "etiqueta", "etiquetas")];
  if (isVideo) {
    job.view = renderVideoResult({
      labels: result.labels,
      durationMs: result.durationMs,
      video: ui.video,
      list: ui.labelList,
      timeline: ui.timeline,
    });
    const duration = job.view.durationMs();
    if (duration) meta.push(`duración ${clock(duration)}`);
    ui.previewHint.textContent = count > 0 ? "Pulsa una etiqueta para saltar al primer instante en que aparece." : "";
  } else {
    job.view = renderImageResult({ labels: result.labels, list: ui.labelList, boxesLayer: ui.boxes });
    if (settings.minConfidence) meta.push(`confianza mínima ${threshold(settings.minConfidence)}`);
    const hasBoxes = job.view.boxCount > 0;
    ui.boxLegend.hidden = !hasBoxes;
    ui.previewHint.textContent = hasBoxes
      ? window.matchMedia("(hover: none)").matches
        ? "Toca una etiqueta para resaltar su caja en la imagen."
        : "Pasa el ratón por una etiqueta para resaltar su caja en la imagen."
      : count > 0
        ? "Las etiquetas de esta imagen no incluyen cajas de posición."
        : "";
  }
  meta.push(job.file.name, seconds(analysisMs));

  setStatus({ tone: "done", title: "Análisis completado", meta: meta.join(" · ") });
  setActions({ reset: true, exportPdf: true });
  announce(`Análisis completado: ${plural(count, "etiqueta", "etiquetas")}.`);
  ui.statusTitle.focus();
}

function showError(error, phase) {
  const { message, help } = describeError(error);
  debug(`analysis failed in phase ${phase}`);

  if (phase === "upload") {
    setStep("upload", "failed", "No completada");
  } else {
    setStep("upload", "done");
    setStep("analyze", "failed", "No completado");
  }
  setStatus({
    tone: "error",
    title: phase === "upload" ? "No se pudo subir el archivo" : "No se pudo completar el análisis",
    meta: job.file.name,
  });
  ui.progressPanel.hidden = true;
  ui.errorPanel.hidden = false;
  ui.errorTitle.textContent = "Qué ha pasado";
  ui.errorMessage.textContent = message;
  ui.errorHelp.textContent = help ?? "";
  setActions({ reset: true });
  announce(`Error: ${message}`);
  ui.statusTitle.focus();
}

/** Se agotó la espera, pero el análisis puede seguir en marcha en AWS. */
function showStillRunning() {
  const elapsed = clock(performance.now() - job.analysisStartedAt);
  const isVideo = job.kind === "video";

  setStep("analyze", "pending", `Sin resultado tras ${elapsed}`);
  setStatus({ tone: "waiting", title: "El análisis sigue en curso", meta: job.fileMeta });
  ui.progressPanel.hidden = true;
  ui.errorPanel.hidden = false;
  ui.errorTitle.textContent = "Todavía no hay resultado";
  ui.errorMessage.textContent = `Rekognition aún no ha terminado (${elapsed} de espera).`;
  ui.errorHelp.textContent = isVideo
    ? "Los vídeos esperan en la cola de Rekognition Video y a veces tardan varios minutos más. El análisis no se ha perdido: pulsa «Seguir esperando» para volver a consultarlo."
    : "El servicio puede estar ocupado. Puedes seguir esperando o probar más tarde.";
  setActions({ resume: true, reset: true });
  announce(`El análisis sigue en curso tras ${elapsed}. Puedes seguir esperando.`);
  ui.resumeButton.focus();
}

function reset({ announceMessage } = {}) {
  if (job) {
    job.controller.abort();
    stopTicker();
    job.view?.cleanup();
    ui.video.pause();
    ui.video.removeAttribute("src");
    ui.video.load();
    ui.image.removeAttribute("src");
    URL.revokeObjectURL(job.objectUrl);
    job = null;
  }
  ui.boxes.replaceChildren();
  ui.boxes.classList.remove("has-active");
  ui.labelList.replaceChildren();
  ui.work.hidden = true;
  ui.idle.hidden = false;
  ui.dropzone.focus();
  if (announceMessage) announce(announceMessage);
}

async function exportPdf() {
  if (!job?.result) return;
  ui.exportButton.disabled = true;
  try {
    const { exportReport } = await import("./report.js");
    await exportReport({
      appName: settings.appName,
      file: job.file,
      format: job.format,
      result: job.result,
      minConfidence: settings.minConfidence,
      analysisMs: job.analysisMs,
      durationMs: job.view?.durationMs?.(),
      image: job.result.kind === "image" ? ui.image : null,
    });
    announce("Informe PDF generado.");
  } catch {
    announce("No se pudo generar el informe PDF.");
  } finally {
    ui.exportButton.disabled = false;
  }
}

// --- Inicio ---------------------------------------------------------------------------

function applyBranding() {
  document.title = `${settings.appName} · Etiquetado de imágenes y vídeo`;
  for (const node of document.querySelectorAll("[data-app-name]")) node.textContent = settings.appName;
  for (const node of document.querySelectorAll("[data-retention-hours]")) {
    node.textContent = String(settings.retentionHours);
  }
  for (const node of document.querySelectorAll("[data-max-size]")) {
    node.textContent = `máx. ${megabytes(settings.maxUploadBytes)}`;
  }
}

function bindDropzone() {
  const open = () => {
    if (!job && configOk) ui.fileInput.click();
  };

  ui.dropzone.addEventListener("click", open);
  ui.dropzone.addEventListener("keydown", (event) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      open();
    }
  });

  ui.fileInput.addEventListener("change", () => {
    const [file] = ui.fileInput.files;
    ui.fileInput.value = "";
    handleFile(file);
  });

  for (const type of ["dragenter", "dragover"]) {
    ui.dropzone.addEventListener(type, (event) => {
      event.preventDefault();
      ui.dropzone.classList.add("is-dragover");
    });
  }
  for (const type of ["dragleave", "drop"]) {
    ui.dropzone.addEventListener(type, () => ui.dropzone.classList.remove("is-dragover"));
  }
  ui.dropzone.addEventListener("drop", (event) => {
    event.preventDefault();
    if (!configOk) return;
    const files = event.dataTransfer?.files;
    if (files?.length > 1) {
      showFileError("Suelta un único archivo.");
      return;
    }
    handleFile(files?.[0]);
  });

  // Evita que soltar un archivo fuera de la zona abra el archivo en la pestaña.
  for (const type of ["dragover", "drop"]) {
    window.addEventListener(type, (event) => event.preventDefault());
  }
}

function init() {
  applyBranding();
  initTheme($("theme-toggle"));
  bindDropzone();
  ui.statusTitle.tabIndex = -1;

  ui.cancelButton.addEventListener("click", () => reset({ announceMessage: "Análisis cancelado." }));
  ui.resetButton.addEventListener("click", () => reset());
  ui.resumeButton.addEventListener("click", () => {
    if (!job?.resultUrl) return;
    waitForResult();
    // El botón se oculta al reanudar: el foco pasa al título de estado.
    ui.statusTitle.focus();
    announce("Seguimos esperando el resultado.");
  });
  ui.exportButton.addEventListener("click", exportPdf);

  if (!configOk) {
    ui.configError.hidden = false;
    ui.dropzone.setAttribute("aria-disabled", "true");
  }

  // Vista previa no soportada por el navegador (p. ej. un MP4 sin H.264): el análisis sigue.
  ui.image.addEventListener("error", () => {
    if (job) ui.previewHint.textContent = "El navegador no puede mostrar la vista previa de este archivo.";
  });
  ui.video.addEventListener("error", () => {
    if (job?.kind === "video" && ui.video.getAttribute("src")) {
      ui.previewHint.textContent = "El navegador no puede reproducir este vídeo; el análisis no se ve afectado.";
    }
  });
}

init();

