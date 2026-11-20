// Utilidades de DOM. Todo el texto se inserta con textContent (nunca innerHTML).

export const $ = (id) => document.getElementById(id);

export function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = text;
  return node;
}

const SVG_NS = "http://www.w3.org/2000/svg";

const ICON_PATHS = {
  check: ["M5 12.5l4.5 4.5L19 7.5"],
  clock: ["M12 3a9 9 0 1 0 0 18a9 9 0 0 0 0-18z", "M12 7.5V12l3 2"],
  alert: ["M12 3a9 9 0 1 0 0 18a9 9 0 0 0 0-18z", "M12 7.5v5.5", "M12 16.5h.01"],
};

export function icon(name, size = 16) {
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", String(size));
  svg.setAttribute("height", String(size));
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "2.4");
  svg.setAttribute("stroke-linecap", "round");
  svg.setAttribute("stroke-linejoin", "round");
  svg.setAttribute("aria-hidden", "true");
  for (const d of ICON_PATHS[name] ?? []) {
    const path = document.createElementNS(SVG_NS, "path");
    path.setAttribute("d", d);
    svg.append(path);
  }
  return svg;
}
