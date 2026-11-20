// Informe PDF con jsPDF (autoalojado en vendor/, se carga solo al exportar).
// Contenido: marca, datos del archivo y del análisis, vista previa con cajas
// (imagen) y tabla de etiquetas.

import { clock, megabytes } from "./format.js";

const JSPDF_SRC = "vendor/jspdf/jspdf.umd.min.js";

const PAGE = { width: 210, height: 297, margin: 18 };
const ACCENT = [13, 107, 97];
const TEXT = [27, 29, 31];
const MUTED = [91, 95, 99];
const RULE = [222, 219, 210];
const HEADER_FILL = [241, 240, 235];
const ZEBRA_FILL = [249, 248, 245];

const pdfNumber = new Intl.NumberFormat("es-ES", { minimumFractionDigits: 1, maximumFractionDigits: 1 });
const pdfPercent = (value) => `${pdfNumber.format(value)} %`;
const pdfThreshold = (value) => `${new Intl.NumberFormat("es-ES", { maximumFractionDigits: 1 }).format(value)} %`;

let loader = null;

function loadJsPdf() {
  if (window.jspdf?.jsPDF) return Promise.resolve(window.jspdf.jsPDF);
  loader ??= new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = JSPDF_SRC;
    script.addEventListener("load", () =>
      window.jspdf?.jsPDF ? resolve(window.jspdf.jsPDF) : reject(new Error("jsPDF no disponible")),
    );
    script.addEventListener("error", () => {
      loader = null;
      reject(new Error("No se pudo cargar jsPDF"));
    });
    document.head.append(script);
  });
  return loader;
}

/** Las fuentes estándar de PDF solo cubren Latin-1: el resto se sustituye. */
const pdfSafe = (text) => String(text).normalize("NFC").replace(/[^ -~ -ÿ]/g, "?");

function slug(fileName) {
  const base = fileName.replace(/\.[^.]+$/, "");
  const ascii = base.normalize("NFD").replace(/[̀-ͯ]/g, "");
  return ascii.replace(/[^a-zA-Z0-9]+/g, "-").replace(/^-+|-+$/g, "").toLowerCase().slice(0, 60) || "archivo";
}

/** Imagen reducida (máx. 1600 px) en JPEG, para no inflar el PDF. */
function imageToJpeg(image) {
  const scale = Math.min(1, 1600 / Math.max(image.naturalWidth, image.naturalHeight));
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(image.naturalWidth * scale);
  canvas.height = Math.round(image.naturalHeight * scale);
  const context = canvas.getContext("2d");
  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.drawImage(image, 0, 0, canvas.width, canvas.height);
  return { dataUrl: canvas.toDataURL("image/jpeg", 0.85), width: canvas.width, height: canvas.height };
}

export async function exportReport({ appName, file, format, result, minConfidence, analysisMs, durationMs, image }) {
  const JsPdf = await loadJsPdf();
  const doc = new JsPdf({ unit: "mm", format: "a4", compress: true });
  const contentWidth = PAGE.width - PAGE.margin * 2;
  const isVideo = result.kind === "video";
  let y = PAGE.margin;

  doc.setProperties({ title: `${appName} — informe de análisis`, creator: appName });

  // --- Cabecera ---------------------------------------------------------------
  doc.setFont("helvetica", "bold");
  doc.setFontSize(18);
  doc.setTextColor(...ACCENT);
  doc.text(pdfSafe(appName), PAGE.margin, y + 6);
  doc.setFont("helvetica", "normal");
  doc.setFontSize(10);
  doc.setTextColor(...MUTED);
  doc.text("Informe de análisis · Amazon Rekognition", PAGE.width - PAGE.margin, y + 6, { align: "right" });
  y += 11;
  doc.setDrawColor(...ACCENT);
  doc.setLineWidth(0.6);
  doc.line(PAGE.margin, y, PAGE.width - PAGE.margin, y);
  y += 9;

  // --- Datos -------------------------------------------------------------------
  const facts = [
    ["Archivo", file.name],
    ["Tipo", `${isVideo ? "Vídeo" : "Imagen"} ${format}`],
    ["Tamaño", megabytes(file.size)],
    ["Fecha", new Intl.DateTimeFormat("es-ES", { dateStyle: "long", timeStyle: "short" }).format(new Date())],
    ["Etiquetas", String(result.labels.length)],
  ];
  if (minConfidence) facts.push(["Confianza mínima", pdfThreshold(minConfidence)]);
  if (isVideo && durationMs) facts.push(["Duración del vídeo", clock(durationMs)]);
  if (analysisMs) facts.push(["Tiempo de análisis", `${pdfNumber.format(analysisMs / 1000)} s`]);

  doc.setFontSize(10);
  for (const [label, value] of facts) {
    doc.setFont("helvetica", "bold");
    doc.setTextColor(...MUTED);
    doc.text(label, PAGE.margin, y);
    doc.setFont("helvetica", "normal");
    doc.setTextColor(...TEXT);
    const lines = doc.splitTextToSize(pdfSafe(value), contentWidth - 45);
    doc.text(lines, PAGE.margin + 45, y);
    y += 6 * lines.length;
  }
  y += 4;

  // --- Vista previa con cajas (solo imagen) ---------------------------------------
  if (!isVideo && image?.naturalWidth) {
    const { dataUrl, width, height } = imageToJpeg(image);
    const maxHeight = 95;
    const scale = Math.min(contentWidth / width, maxHeight / height);
    const drawWidth = width * scale;
    const drawHeight = height * scale;
    const x = PAGE.margin + (contentWidth - drawWidth) / 2;
    doc.addImage(dataUrl, "JPEG", x, y, drawWidth, drawHeight);

    doc.setDrawColor(...ACCENT);
    doc.setLineWidth(0.5);
    for (const label of result.labels) {
      for (const { boundingBox: box } of label.instances ?? []) {
        doc.rect(x + box.left * drawWidth, y + box.top * drawHeight, box.width * drawWidth, box.height * drawHeight);
      }
    }
    y += drawHeight + 10;
  }

  // --- Tabla de etiquetas ---------------------------------------------------------------
  const columns = isVideo
    ? [
        { title: "Etiqueta", width: 66 },
        { title: "Confianza máx.", width: 30, align: "right" },
        { title: "Primera", width: 24, align: "right" },
        { title: "Última", width: 24, align: "right" },
        { title: "Detecciones", width: 30, align: "right" },
      ]
    : [
        { title: "Etiqueta", width: 104 },
        { title: "Confianza", width: 35, align: "right" },
        { title: "Cajas", width: 35, align: "right" },
      ];
  const rowHeight = 7;

  const rows = result.labels.map((label) =>
    isVideo
      ? [label.name, pdfPercent(label.confidence), clock(label.firstSeenMs), clock(label.lastSeenMs), String(label.occurrences)]
      : [label.name, pdfPercent(label.confidence), String((label.instances ?? []).length)],
  );

  const drawRow = (cells, { header = false, zebra = false } = {}) => {
    if (header || zebra) {
      doc.setFillColor(...(header ? HEADER_FILL : ZEBRA_FILL));
      doc.rect(PAGE.margin, y - 5, contentWidth, rowHeight, "F");
    }
    doc.setFont("helvetica", header ? "bold" : "normal");
    doc.setFontSize(header ? 9 : 10);
    doc.setTextColor(...(header ? MUTED : TEXT));
    let x = PAGE.margin;
    columns.forEach((column, index) => {
      const text = doc.splitTextToSize(pdfSafe(cells[index]), column.width - 4)[0] ?? "";
      if (column.align === "right") doc.text(text, x + column.width - 2, y, { align: "right" });
      else doc.text(text, x + 2, y);
      x += column.width;
    });
    y += rowHeight;
  };

  const headerRow = columns.map((column) => column.title);
  const bottomLimit = PAGE.height - PAGE.margin - 10;

  doc.setFont("helvetica", "bold");
  doc.setFontSize(12);
  doc.setTextColor(...TEXT);
  if (y + 20 > bottomLimit) {
    doc.addPage();
    y = PAGE.margin;
  }
  doc.text("Etiquetas detectadas", PAGE.margin, y);
  y += 8;

  if (rows.length === 0) {
    doc.setFont("helvetica", "normal");
    doc.setFontSize(10);
    doc.setTextColor(...MUTED);
    doc.text("Rekognition no ha detectado etiquetas por encima de la confianza mínima.", PAGE.margin, y);
  } else {
    drawRow(headerRow, { header: true });
    rows.forEach((cells, index) => {
      if (y > bottomLimit) {
        doc.addPage();
        y = PAGE.margin + 5;
        drawRow(headerRow, { header: true });
      }
      drawRow(cells, { zebra: index % 2 === 1 });
    });
    doc.setDrawColor(...RULE);
    doc.setLineWidth(0.3);
    doc.line(PAGE.margin, y - 5, PAGE.width - PAGE.margin, y - 5);
  }

  // --- Pie en todas las páginas --------------------------------------------------------------
  const pages = doc.getNumberOfPages();
  for (let page = 1; page <= pages; page += 1) {
    doc.setPage(page);
    doc.setFont("helvetica", "normal");
    doc.setFontSize(8);
    doc.setTextColor(...MUTED);
    doc.text(pdfSafe(`${appName} · Etiquetas generadas por Amazon Rekognition`), PAGE.margin, PAGE.height - 10);
    doc.text(`Página ${page} de ${pages}`, PAGE.width - PAGE.margin, PAGE.height - 10, { align: "right" });
  }

  doc.save(`informe-${slug(file.name)}.pdf`);
}
