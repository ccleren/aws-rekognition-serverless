// Conmutador claro/oscuro. Sin elección guardada se sigue prefers-color-scheme;
// al pulsar se guarda la elección (theme-init.js la aplica antes de pintar).

const media = window.matchMedia("(prefers-color-scheme: dark)");

function currentTheme() {
  const forced = document.documentElement.getAttribute("data-theme");
  if (forced === "light" || forced === "dark") return forced;
  return media.matches ? "dark" : "light";
}

function updateButton(button) {
  const next = currentTheme() === "dark" ? "claro" : "oscuro";
  button.setAttribute("aria-label", `Cambiar a tema ${next}`);
  button.title = `Cambiar a tema ${next}`;
}

export function initTheme(button) {
  updateButton(button);
  media.addEventListener("change", () => updateButton(button));

  button.addEventListener("click", () => {
    const next = currentTheme() === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    try {
      localStorage.setItem("theme", next);
    } catch {
      // Sin almacenamiento disponible el cambio dura hasta recargar.
    }
    updateButton(button);
  });
}
