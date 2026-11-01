/* SPDX-License-Identifier: Apache-2.0
   tockmox-ui-kit shell script. Loaded synchronously in <head>, before the stylesheets, from the app's
   own origin (CSP script-src 'self'; nothing inline).

   1. Theme, before first paint: the viewer's stored choice (localStorage "tockmox-theme": "light" or
      "dark") wins; with none stored the page follows the system (prefers-color-scheme). The result is
      written to <html data-theme>, which is the one switch the tokens read. Without JavaScript the
      page renders the dark default, which is what every Tockmox page did before 0.9.0.
   2. After load: the Appearance control (System / Light / Dark) and the header menus (<details>):
      Escape or a click elsewhere closes an open menu and returns focus to its button.
   3. Arrow keys within a [data-roving] list of links.
   Every storage access is wrapped: a blocked store means "follow the system", never an error. */
(function () {
  "use strict";
  var KEY = "tockmox-theme";
  var root = document.documentElement;

  function stored() {
    try { var v = window.localStorage.getItem(KEY); return v === "light" || v === "dark" ? v : null; }
    catch (e) { return null; }
  }
  function systemTheme() {
    try { return window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark"; }
    catch (e) { return "dark"; }
  }
  function apply() {
    var pref = stored();
    root.setAttribute("data-theme", pref || systemTheme());
    root.setAttribute("data-theme-pref", pref || "system");
  }
  apply();

  try { window.matchMedia("(prefers-color-scheme: light)").addEventListener("change", function () { apply(); paint(); }); }
  catch (e) { /* old engines: the page keeps the theme it loaded with */ }
  window.addEventListener("storage", function (ev) { if (ev.key === KEY) { apply(); paint(); } });

  function paint() {
    var pref = root.getAttribute("data-theme-pref") || "system";
    var buttons = document.querySelectorAll("[data-theme-set]");
    for (var i = 0; i < buttons.length; i++) {
      var b = buttons[i], v = b.getAttribute("data-theme-set");
      b.setAttribute("aria-pressed", String(v === pref));
      if (v === "system") {
        var now = b.querySelector("[data-theme-now]");
        if (now) { now.textContent = "now " + systemTheme(); }
      }
    }
  }

  function choose(v) {
    try {
      if (v === "system") { window.localStorage.removeItem(KEY); }
      else { window.localStorage.setItem(KEY, v); }
    } catch (e) { /* storage blocked: the choice lasts for this page only */
      root.setAttribute("data-theme", v === "system" ? systemTheme() : v);
      root.setAttribute("data-theme-pref", v);
      paint();
      return;
    }
    apply();
    paint();
  }

  function closeMenus(except) {
    var open = document.querySelectorAll("details.menu-d[open]");
    for (var i = 0; i < open.length; i++) { if (open[i] !== except) { open[i].removeAttribute("open"); } }
  }

  document.addEventListener("DOMContentLoaded", function () {
    var controls = document.querySelectorAll("[data-appearance]");
    for (var i = 0; i < controls.length; i++) { controls[i].hidden = false; }
    var buttons = document.querySelectorAll("[data-theme-set]");
    for (var j = 0; j < buttons.length; j++) {
      buttons[j].addEventListener("click", function (ev) { choose(ev.currentTarget.getAttribute("data-theme-set")); });
    }
    paint();

    var menus = document.querySelectorAll("details.menu-d");
    for (var k = 0; k < menus.length; k++) {
      menus[k].addEventListener("toggle", function (ev) { if (ev.target.open) { closeMenus(ev.target); } });
    }
    document.addEventListener("click", function (ev) {
      var inside = ev.target.closest ? ev.target.closest("details.menu-d") : null;
      closeMenus(inside);
    });
    // Roving arrows (kit 0.4.1): inside a [data-roving] list, the arrow keys move between its links; Tab
    // still moves in reading order. Status uses it for each band of the stack (TM-1305).
    document.addEventListener("keydown", function (ev) {
      var keys = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 };
      if (!(ev.key in keys) || ev.altKey || ev.ctrlKey || ev.metaKey) { return; }
      var list = ev.target.closest ? ev.target.closest("[data-roving]") : null;
      if (!list || ev.target.tagName !== "A") { return; }
      var links = list.querySelectorAll("a[href]");
      for (var i = 0; i < links.length; i++) {
        if (links[i] === ev.target) {
          var next = links[i + keys[ev.key]];
          if (next) { next.focus(); ev.preventDefault(); }
          return;
        }
      }
    });
    document.addEventListener("keydown", function (ev) {
      if (ev.key !== "Escape") { return; }
      var open = document.querySelector("details.menu-d[open]");
      if (!open) { return; }
      open.removeAttribute("open");
      var s = open.querySelector("summary");
      if (s) { s.focus(); }
    });
  });
})();
