// org.nvim documentation site: theme toggle, mobile menu and search.
// The search index (search-index.js, built by scripts/site/build.lua) is a
// list of { t: title, u: url from the site root, s: section, k: kind }; it is
// loaded with a <script> tag on first use so the site also works from file://.
(function () {
  "use strict";
  var root = document.body.getAttribute("data-root") || "";
  var html = document.documentElement;

  // Theme ------------------------------------------------------------------
  function systemDark() {
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  }
  var themeBtn = document.querySelector(".theme");
  if (themeBtn) {
    themeBtn.addEventListener("click", function () {
      var cur = html.dataset.theme || (systemDark() ? "dark" : "light");
      var next = cur === "dark" ? "light" : "dark";
      html.dataset.theme = next;
      try {
        localStorage.setItem("org-theme", next);
      } catch (e) {}
    });
  }

  // Mobile menu ------------------------------------------------------------
  var menuBtn = document.querySelector(".menu");
  if (menuBtn) {
    menuBtn.addEventListener("click", function () {
      var open = document.body.classList.toggle("nav-open");
      menuBtn.setAttribute("aria-expanded", open ? "true" : "false");
    });
    document.addEventListener("click", function (e) {
      if (
        document.body.classList.contains("nav-open") &&
        !e.target.closest(".sidebar") &&
        !e.target.closest(".menu")
      ) {
        document.body.classList.remove("nav-open");
        menuBtn.setAttribute("aria-expanded", "false");
      }
    });
  }
  var current = document.querySelector('.sidebar a[aria-current="page"]');
  if (current && current.scrollIntoView) {
    current.scrollIntoView({ block: "center" });
    window.scrollTo(0, 0);
  }

  // Search -----------------------------------------------------------------
  var input = document.getElementById("search");
  var list = document.getElementById("search-results");
  if (!input || !list) return;
  var index = null;
  var loading = false;
  var selected = -1;
  var results = [];

  function load(cb) {
    if (index) return cb();
    if (loading) return;
    loading = true;
    var s = document.createElement("script");
    s.src = root + "search-index.js";
    s.onload = function () {
      index = (window.ORG_SEARCH || []).map(function (e) {
        e.l = norm(e.t);
        e.sl = norm(e.s || "");
        return e;
      });
      cb();
    };
    document.head.appendChild(s);
  }

  var KIND = { tag: "tag", heading: "section", page: "page", option: "option" };

  // agenda_files, agenda-files and "agenda files" all match each other
  function norm(s) {
    return s.toLowerCase().replace(/[_\-]+/g, " ");
  }

  // Every word of the query must occur in the title or section; matches at
  // the start of the title, then of a word, then anywhere, rank first.
  function find(q) {
    var nq = norm(q).trim();
    var words = nq.split(/\s+/).filter(Boolean);
    if (!words.length) return [];
    var out = [];
    for (var i = 0; i < index.length; i++) {
      var e = index[i];
      var score = 0;
      var ok = true;
      for (var w = 0; w < words.length; w++) {
        var word = words[w];
        var at = e.l.indexOf(word);
        if (at === 0) score += 10;
        else if (at > 0) score += /[\s.:(]/.test(e.l.charAt(at - 1)) ? 6 : 3;
        else if (e.sl.indexOf(word) >= 0) score += 1;
        else {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      if (e.l === nq) score += 20;
      if (e.k === "page") score += 2;
      score -= e.t.length / 200;
      out.push({ e: e, score: score });
    }
    out.sort(function (a, b) {
      return b.score - a.score;
    });
    return out.slice(0, 40).map(function (r) {
      return r.e;
    });
  }

  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  function render() {
    var q = input.value.trim();
    if (!q) {
      list.hidden = true;
      return;
    }
    results = find(q);
    selected = results.length ? 0 : -1;
    if (!results.length) {
      list.innerHTML = '<li class="empty">No results for “' + esc(q) + "”</li>";
    } else {
      list.innerHTML = results
        .map(function (e, i) {
          return (
            '<li role="option" aria-selected="' +
            (i === selected) +
            '"><a href="' +
            esc(root + e.u) +
            '"><span class="k">' +
            (KIND[e.k] || e.k) +
            '</span><span class="t">' +
            esc(e.t) +
            '</span><span class="s">' +
            esc(e.s || "") +
            "</span></a></li>"
          );
        })
        .join("");
    }
    list.hidden = false;
  }

  function move(d) {
    if (!results.length) return;
    selected = (selected + d + results.length) % results.length;
    var items = list.querySelectorAll("li");
    for (var i = 0; i < items.length; i++) items[i].setAttribute("aria-selected", i === selected);
    if (items[selected]) items[selected].scrollIntoView({ block: "nearest" });
  }

  input.addEventListener("focus", function () {
    load(render);
  });
  input.addEventListener("input", function () {
    load(render);
  });
  input.addEventListener("keydown", function (e) {
    if (e.key === "ArrowDown") {
      move(1);
      e.preventDefault();
    } else if (e.key === "ArrowUp") {
      move(-1);
      e.preventDefault();
    } else if (e.key === "Enter") {
      if (results[selected]) window.location.href = root + results[selected].u;
      list.hidden = true;
    } else if (e.key === "Escape") {
      input.value = "";
      list.hidden = true;
      input.blur();
    }
  });
  document.addEventListener("click", function (e) {
    if (!e.target.closest(".search")) list.hidden = true;
  });
  // "/" focuses the search, as in many docs sites (and Vim)
  document.addEventListener("keydown", function (e) {
    var t = e.target;
    var typing = t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable);
    if (e.key === "/" && !typing && !e.ctrlKey && !e.metaKey && !e.altKey) {
      e.preventDefault();
      input.focus();
      input.select();
    }
  });
})();
