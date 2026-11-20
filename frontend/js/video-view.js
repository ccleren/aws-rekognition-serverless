// Resultado de vídeo: lista agregada por etiqueta con su intervalo de aparición.
// Pulsar una etiqueta lleva el vídeo a su primera aparición (firstSeenMs) y
// marca el intervalo en la línea de tiempo.

import { el } from "./dom.js";
import { clock, percent } from "./format.js";

const MIN_RANGE_PERCENT = 1.5; // para que una aparición puntual siga siendo visible

/**
 * @returns {{ cleanup: () => void }}
 */
export function renderVideoResult({ labels, durationMs, video, list, timeline }) {
  const rows = [];
  let active = null;
  let duration = durationMs > 0 ? durationMs : 0;

  const span = (startMs, endMs) => {
    if (!duration) return { left: 0, width: 0 };
    const left = Math.min(100, (startMs / duration) * 100);
    const width = Math.max(MIN_RANGE_PERCENT, ((endMs - startMs) / duration) * 100);
    return { left, width: Math.min(width, 100 - left) };
  };

  list.replaceChildren();

  labels.forEach((label, index) => {
    const row = el("button", "label-row");
    row.type = "button";
    row.setAttribute("aria-pressed", "false");
    row.setAttribute(
      "aria-label",
      `${label.name}, confianza ${percent(label.confidence)}, de ${clock(label.firstSeenMs)} a ${clock(label.lastSeenMs)}. Ir a ${clock(label.firstSeenMs)}`,
    );

    const head = el("span", "label-head");
    head.append(
      el("span", "label-name", label.name),
      el("span", "label-value", `${percent(label.confidence)} · ${clock(label.firstSeenMs)} – ${clock(label.lastSeenMs)}`),
    );

    const bar = el("span", "bar");
    const fill = el("span", "bar-fill");
    bar.append(fill);
    row.append(head, bar);

    row.addEventListener("click", () => {
      active = index;
      video.currentTime = label.firstSeenMs / 1000;
      update();
    });

    const item = el("li");
    item.append(row);
    list.append(item);
    rows.push({ row, fill, label });
  });

  function layoutBars() {
    for (const { fill, label } of rows) {
      const { left, width } = span(label.firstSeenMs, label.lastSeenMs);
      fill.style.left = `${left}%`;
      fill.style.width = `${width}%`;
    }
  }

  function renderTicks() {
    timeline.ticks.replaceChildren();
    if (!duration) return;
    for (const fraction of [0, 0.25, 0.5, 0.75, 1]) {
      timeline.ticks.append(el("li", null, clock(duration * fraction)));
    }
  }

  function update() {
    rows.forEach(({ row }, index) => {
      row.classList.toggle("is-active", index === active);
      row.setAttribute("aria-pressed", String(index === active));
    });

    const label = active === null ? null : labels[active];
    timeline.range.hidden = !label || !duration;
    timeline.marker.hidden = !label || !duration;
    if (label && duration) {
      const { left, width } = span(label.firstSeenMs, label.lastSeenMs);
      timeline.range.style.left = `${left}%`;
      timeline.range.style.width = `${width}%`;
      timeline.marker.style.left = `${left}%`;
    }
  }

  function updateProgress() {
    if (!duration) return;
    const progress = Math.min(100, ((video.currentTime * 1000) / duration) * 100);
    timeline.progress.style.width = `${progress}%`;
  }

  // Si Rekognition no informó la duración, se usa la del propio vídeo.
  function onMetadata() {
    if (!duration && Number.isFinite(video.duration)) {
      duration = Math.round(video.duration * 1000);
      layoutBars();
      renderTicks();
      update();
    }
    timeline.root.hidden = !duration;
  }

  video.addEventListener("timeupdate", updateProgress);
  video.addEventListener("loadedmetadata", onMetadata);
  if (video.readyState >= 1) onMetadata();

  layoutBars();
  renderTicks();
  update();
  updateProgress();
  timeline.root.hidden = !duration;

  return {
    durationMs: () => duration,
    cleanup: () => {
      video.removeEventListener("timeupdate", updateProgress);
      video.removeEventListener("loadedmetadata", onMetadata);
    },
  };
}
