// Script clásico y mínimo que se ejecuta antes de pintar: aplica el tema
// elegido por el usuario (si lo hay) para evitar el parpadeo claro/oscuro.
// Sin preferencia guardada manda prefers-color-scheme (CSS).
(function () {
  try {
    var theme = localStorage.getItem("theme");
    if (theme === "light" || theme === "dark") {
      document.documentElement.setAttribute("data-theme", theme);
    }
  } catch (error) {
    // localStorage puede no estar disponible (modo privado): se usa el del sistema.
  }
})();
