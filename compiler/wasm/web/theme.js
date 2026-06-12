// Shared light/dark theme handling for the explorer (index.html) and the tour
// (tour.html). The default follows the OS (prefers-color-scheme); an explicit
// choice is saved to localStorage and wins thereafter. A header button with
// id="themeToggle" flips it. Loaded synchronously in <head> so the theme is set
// on <html> before first paint (no flash). The colors themselves live in
// aero.css under :root / :root[data-theme="dark"].
(function () {
    const KEY = "dmdwasm.theme";
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const stored = () => { try { return localStorage.getItem(KEY); } catch { return null; } };
    const resolve = () => stored() || (mq.matches ? "dark" : "light");

    function apply(theme) {
        document.documentElement.dataset.theme = theme;
        const btn = document.getElementById("themeToggle");
        if (btn) {
            const dark = theme === "dark";
            btn.textContent = dark ? "☀" : "☾";           // show what a click switches *to*
            btn.title = dark ? "Switch to light theme" : "Switch to dark theme";
            btn.setAttribute("aria-pressed", String(dark));
        }
    }

    apply(resolve());   // set <html data-theme> before paint (button wired up below)

    // Follow OS changes only while the user hasn't pinned an explicit choice.
    mq.addEventListener?.("change", () => { if (!stored()) apply(resolve()); });

    document.addEventListener("DOMContentLoaded", () => {
        apply(resolve());                              // re-sync now the button exists
        const btn = document.getElementById("themeToggle");
        btn?.addEventListener("click", () => {
            const next = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
            try { localStorage.setItem(KEY, next); } catch {}
            apply(next);
        });
    });
})();
