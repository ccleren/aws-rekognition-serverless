// Resultado de imagen: cajas (boundingBox) sobre la vista previa y lista de
// etiquetas. Pasar el ratón o el foco por una etiqueta resalta sus cajas;
// pulsarla la deja fijada.

import { el } from "./dom.js";
import { percent, plural } from "./format.js";

// Altura mínima (px) sobre la caja para que la etiqueta quepa fuera de ella.
const TAG_SPACE_PX = 24;

/**
 * @returns {{ boxCount: number, cleanup: () => void }}
 */
export function renderImageResult({ labels, list, boxesLayer }) {
  const rows = [];
  const boxesByLabel = labels.map(() => []);
  let hovered = null;
  let pinned = null;

  boxesLayer.replaceChildren();
  list.replaceChildren();

  labels.forEach((label, index) => {
    for (const { boundingBox: box } of label.instances ?? []) {
      const node = el("div", "box");
      // Posición en porcentaje sobre el contenedor, que mide lo mismo que la
      // imagen mostrada: las cajas acompañan a la imagen al redimensionar.
      node.style.left = `${box.left * 100}%`;
      node.style.top = `${box.top * 100}%`;
      node.style.width = `${box.width * 100}%`;
      node.style.height = `${box.height * 100}%`;
      node.append(el("span", "box-tag", `${label.name} · ${percent(label.confidence)}`));
      boxesLayer.append(node);
      boxesByLabel[index].push(node);
    }

    const row = el("button", "label-row");
    row.type = "button";
    row.setAttribute("aria-pressed", "false");

    const head = el("span", "label-head");
    const name = el("span", "label-name", label.name);
    const count = boxesByLabel[index].length;
    if (count > 0) {
      name.append(el("span", "label-boxes", `· ${plural(count, "caja", "cajas")}`));
    }
    head.append(name, el("span", "label-value", percent(label.confidence)));

    const bar = el("span", "bar");
    const fill = el("span", "bar-fill");
    fill.style.width = `${Math.min(100, Math.max(0, label.confidence))}%`;
    bar.append(fill);
    row.append(head, bar);

    row.addEventListener("mouseenter", () => setHovered(index));
    row.addEventListener("mouseleave", () => setHovered(null));
    row.addEventListener("focus", () => setHovered(index));
    row.addEventListener("blur", () => setHovered(null));
    row.addEventListener("click", () => {
      pinned = pinned === index ? null : index;
      update();
    });

    const item = el("li");
    item.append(row);
    list.append(item);
    rows.push(row);
  });

  function setHovered(index) {
    hovered = index;
    update();
  }

  function update() {
    const active = hovered ?? pinned;
    rows.forEach((row, index) => {
      row.classList.toggle("is-active", index === active);
      row.setAttribute("aria-pressed", String(index === pinned));
    });
    boxesByLabel.forEach((boxes, index) => {
      for (const box of boxes) box.classList.toggle("is-active", index === active);
    });
    boxesLayer.classList.toggle("has-active", active !== null && boxesByLabel[active].length > 0);
  }

  // La etiqueta de la caja va encima; si la caja está pegada al borde superior
  // (en píxeles del tamaño mostrado) va dentro. Se recalcula al redimensionar.
  const placeTags = () => {
    for (const box of boxesLayer.children) {
      box.classList.toggle("tag-inside", box.offsetTop < TAG_SPACE_PX);
    }
  };
  const observer = new ResizeObserver(placeTags);
  observer.observe(boxesLayer);

  return {
    boxCount: boxesByLabel.reduce((total, boxes) => total + boxes.length, 0),
    cleanup: () => observer.disconnect(),
  };
}
