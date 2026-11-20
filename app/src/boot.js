// Runs in <head> before first paint: the theme the commander chose here, else the system's.
(function () {
  var theme = null;
  try { theme = window.localStorage.getItem("chartroom-theme"); } catch (e) { theme = null; }
  if (theme !== "light" && theme !== "dark") {
    theme = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }
  document.documentElement.setAttribute("data-theme", theme);
})();
