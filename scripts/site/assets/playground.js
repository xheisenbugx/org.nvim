// org.nvim documentation site: the playground page (playground.html, built by
// scripts/site/playground.lua). A small asciicast v2 player for the tutor
// recordings (scripts/playground/record.lua), and the "Try the syntax" box.
//
// The player understands what the recorder writes: text, CUP (ESC[r;cH),
// ED 2 (ESC[2J), EL (ESC[K), SGR with bold, italic, underline, strikethrough
// and 24-bit colors, the cursor shape (ESC[n q) and showing/hiding the
// cursor; "i" events are shown as the keys pressed, "m" markers are the
// exercises. A recording is loaded with a <script> tag (playground/<lesson>.js
// calls window.ORG_CAST) so the page also works from file://.
(function () {
  "use strict";
  var root = document.body.getAttribute("data-root") || "";

  // Casts ------------------------------------------------------------------
  var casts = {};
  var waiting = {};
  window.ORG_CAST = function (name, text) {
    casts[name] = parse(text);
    (waiting[name] || []).forEach(function (cb) {
      cb(casts[name]);
    });
    delete waiting[name];
  };

  function load(name, src, cb) {
    if (casts[name]) return cb(casts[name]);
    if (waiting[name]) return waiting[name].push(cb);
    waiting[name] = [cb];
    var s = document.createElement("script");
    s.src = root + src;
    s.onerror = function () {
      cb(null);
    };
    document.head.appendChild(s);
  }

  function parse(text) {
    var lines = text.split("\n").filter(Boolean);
    var header = JSON.parse(lines[0]);
    var events = [];
    for (var i = 1; i < lines.length; i++) events.push(JSON.parse(lines[i]));
    var theme = header.theme || {};
    var cast = {
      cols: header.width,
      rows: header.height,
      fg: theme.fg || "#e0e2ea",
      bg: theme.bg || "#14161b",
      events: events,
      markers: [],
      inputs: [],
      duration: events.length ? events[events.length - 1][0] : 0,
    };
    events.forEach(function (e) {
      if (e[1] === "m") cast.markers.push({ t: e[0], label: e[2] });
      else if (e[1] === "i") cast.inputs.push({ t: e[0], key: e[2] });
    });
    cast.duration += 2;
    return cast;
  }

  // Terminal ---------------------------------------------------------------
  // A cell is [char, style]; style is "" or "b i u s fg bg" as a key.
  function Term(cols, rows) {
    this.cols = cols;
    this.rows = rows;
    this.reset();
  }
  Term.prototype.reset = function () {
    this.grid = [];
    for (var r = 0; r < this.rows; r++) this.grid.push(this.blank());
    this.row = 0;
    this.col = 0;
    this.style = "";
    this.cursorShown = true;
    this.shape = 2;
    this.dirty = {};
    for (var k = 0; k < this.rows; k++) this.dirty[k] = true;
  };
  Term.prototype.blank = function () {
    var line = [];
    for (var c = 0; c < this.cols; c++) line.push([" ", ""]);
    return line;
  };

  // East Asian wide and emoji code points take two cells, as in Neovim.
  function wide(cp) {
    return (
      (cp >= 0x1100 && cp <= 0x115f) ||
      (cp >= 0x2e80 && cp <= 0xa4cf) ||
      (cp >= 0xac00 && cp <= 0xd7a3) ||
      (cp >= 0xf900 && cp <= 0xfaff) ||
      (cp >= 0xfe30 && cp <= 0xfe4f) ||
      (cp >= 0xff00 && cp <= 0xff60) ||
      (cp >= 0xffe0 && cp <= 0xffe6) ||
      (cp >= 0x1f300 && cp <= 0x1faff) ||
      (cp >= 0x20000 && cp <= 0x3fffd)
    );
  }

  Term.prototype.put = function (ch) {
    var w = wide(ch.codePointAt(0)) ? 2 : 1;
    if (this.row < this.rows && this.col < this.cols) {
      this.grid[this.row][this.col] = [ch, this.style];
      if (w === 2 && this.col + 1 < this.cols) this.grid[this.row][this.col + 1] = ["", this.style];
      this.dirty[this.row] = true;
    }
    this.col += w;
  };

  Term.prototype.sgr = function (params) {
    var p = params.length ? params.split(";").map(Number) : [0];
    var st = this.style ? this.style.split(" ") : ["", "", "", "", "", ""];
    for (var i = 0; i < p.length; i++) {
      var n = p[i];
      if (n === 0) st = ["", "", "", "", "", ""];
      else if (n === 1) st[0] = "b";
      else if (n === 3) st[1] = "i";
      else if (n === 4) st[2] = "u";
      else if (n === 9) st[3] = "s";
      else if (n === 22) st[0] = "";
      else if (n === 23) st[1] = "";
      else if (n === 24) st[2] = "";
      else if (n === 29) st[3] = "";
      else if (n === 39) st[4] = "";
      else if (n === 49) st[5] = "";
      else if ((n === 38 || n === 48) && p[i + 1] === 2) {
        var hex =
          "#" +
          [p[i + 2], p[i + 3], p[i + 4]]
            .map(function (v) {
              return ("0" + (v | 0).toString(16)).slice(-2);
            })
            .join("");
        st[n === 38 ? 4 : 5] = hex;
        i += 4;
      }
    }
    this.style = st.join("").length ? st.join(" ") : "";
  };

  Term.prototype.write = function (data) {
    var i = 0;
    var n = data.length;
    while (i < n) {
      var c = data.charCodeAt(i);
      if (c === 27 && data[i + 1] === "[") {
        var j = i + 2;
        while (j < n && !/[@-~]/.test(data[j])) j++;
        var body = data.slice(i + 2, j);
        var fin = data[j];
        this.csi(body, fin);
        i = j + 1;
      } else if (c === 13) {
        this.col = 0;
        i++;
      } else if (c === 10) {
        this.row = Math.min(this.row + 1, this.rows - 1);
        i++;
      } else if (c < 32) {
        i++;
      } else {
        var cp = data.codePointAt(i);
        var ch = String.fromCodePoint(cp);
        this.put(ch);
        i += ch.length;
      }
    }
  };

  Term.prototype.csi = function (body, fin) {
    var r, c;
    if (fin === "H" || fin === "f") {
      var p = body.split(";");
      r = (parseInt(p[0], 10) || 1) - 1;
      c = (parseInt(p[1], 10) || 1) - 1;
      this.row = Math.min(Math.max(r, 0), this.rows - 1);
      this.col = Math.min(Math.max(c, 0), this.cols - 1);
    } else if (fin === "J") {
      if (body === "2" || body === "3") {
        for (r = 0; r < this.rows; r++) {
          this.grid[r] = this.blank();
          this.dirty[r] = true;
        }
      }
    } else if (fin === "K") {
      var line = this.grid[this.row];
      for (c = this.col; c < this.cols; c++) line[c] = [" ", this.style];
      this.dirty[this.row] = true;
    } else if (fin === "m") {
      this.sgr(body);
    } else if (fin === "q" && / $/.test(body)) {
      this.shape = parseInt(body, 10) || 2;
    } else if (body === "?25l") {
      this.cursorShown = false;
    } else if (body === "?25h") {
      this.cursorShown = true;
    }
  };

  // Rendering --------------------------------------------------------------
  function esc(s) {
    return s.replace(/[&<>]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c];
    });
  }

  var styleCache = {};
  function css(style) {
    if (styleCache[style] !== undefined) return styleCache[style];
    var st = style.split(" ");
    var out = [];
    if (st[0]) out.push("font-weight:700");
    if (st[1]) out.push("font-style:italic");
    var deco = [];
    if (st[2]) deco.push("underline");
    if (st[3]) deco.push("line-through");
    if (deco.length) out.push("text-decoration:" + deco.join(" "));
    if (st[4]) out.push("color:" + st[4]);
    if (st[5]) out.push("background:" + st[5]);
    return (styleCache[style] = out.join(";"));
  }

  function rowHTML(line) {
    var out = "";
    var cur = null;
    var run = "";
    for (var c = 0; c < line.length; c++) {
      var cell = line[c];
      if (cell[0] === "") continue;
      if (cell[1] !== cur) {
        if (run) out += cur ? '<span style="' + css(cur) + '">' + esc(run) + "</span>" : esc(run);
        run = "";
        cur = cell[1];
      }
      run += cell[0];
    }
    if (run) out += cur ? '<span style="' + css(cur) + '">' + esc(run) + "</span>" : esc(run);
    return out;
  }

  function rowText(line) {
    return line
      .map(function (cell) {
        return cell[0];
      })
      .join("")
      .replace(/\s+$/, "");
  }

  // Keys -------------------------------------------------------------------
  // The keys shown over the screen: the last few pressed within KEY_SHOW
  // seconds; characters typed in a row are one word.
  var KEY_SHOW = 1.6;
  function recentKeys(inputs, t) {
    var groups = [];
    for (var i = 0; i < inputs.length && inputs[i].t <= t; i++) {
      var k = inputs[i].key;
      var typed = k.length === 1 || (k.length === 2 && k.codePointAt(0) > 0xffff);
      var last = groups[groups.length - 1];
      if (typed && last && last.typed && inputs[i].t - last.t < 0.5) {
        last.text += k;
        last.t = inputs[i].t;
      } else {
        groups.push({ text: k, typed: typed, t: inputs[i].t });
      }
    }
    return groups
      .filter(function (g) {
        return t - g.t <= KEY_SHOW;
      })
      .slice(-3);
  }

  function fmtTime(s) {
    s = Math.max(0, Math.floor(s));
    return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2);
  }

  // Player -----------------------------------------------------------------
  var ICON_PLAY = '<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path fill="currentColor" d="M7 4.5v15l13-7.5z"/></svg>';
  var ICON_PAUSE = '<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path fill="currentColor" d="M6 4h4v16H6zm8 0h4v16h-4z"/></svg>';
  var ICON_PREV = '<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path fill="currentColor" d="M6 5h2v14H6zm3.5 7L19 5v14z"/></svg>';
  var ICON_NEXT = '<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path fill="currentColor" d="M16 5h2v14h-2zM5 5l9.5 7L5 19z"/></svg>';

  function Player(el, cast, section) {
    var self = this;
    this.el = el;
    this.cast = cast;
    this.section = section;
    this.term = new Term(cast.cols, cast.rows);
    this.t = 0;
    this.next = 0;
    this.playing = false;
    this.speed = 1;

    el.innerHTML =
      '<div class="pg-screen" style="--pg-fg:' +
      cast.fg +
      ";--pg-bg:" +
      cast.bg +
      '"><div class="pg-rows"></div><div class="pg-cursor" aria-hidden="true"></div>' +
      '<div class="pg-keys" aria-live="off"></div>' +
      '<button type="button" class="pg-big-play" aria-label="Play">' +
      ICON_PLAY +
      "</button></div>" +
      '<div class="pg-controls">' +
      '<button type="button" class="pg-btn pg-prev" aria-label="Previous exercise" title="Previous exercise ( [ )">' +
      ICON_PREV +
      "</button>" +
      '<button type="button" class="pg-btn pg-play" aria-label="Play" title="Play / pause (Space)">' +
      ICON_PLAY +
      "</button>" +
      '<button type="button" class="pg-btn pg-next" aria-label="Next exercise" title="Next exercise ( ] )">' +
      ICON_NEXT +
      "</button>" +
      '<span class="pg-time">0:00</span>' +
      '<div class="pg-track"><input type="range" class="pg-seek" min="0" max="' +
      cast.duration +
      '" step="0.05" value="0" aria-label="Position"><div class="pg-ticks"></div></div>' +
      '<span class="pg-dur">' +
      fmtTime(cast.duration) +
      "</span>" +
      '<select class="pg-speed" aria-label="Speed"><option value="0.5">0.5×</option>' +
      '<option value="1" selected>1×</option><option value="1.5">1.5×</option><option value="2">2×</option></select>' +
      '<button type="button" class="pg-btn pg-copy" title="Copy the text on the screen">Copy</button>' +
      "</div>" +
      '<div class="pg-chapter" aria-live="polite"></div>';

    this.screen = el.querySelector(".pg-screen");
    this.rowsEl = el.querySelector(".pg-rows");
    this.cursorEl = el.querySelector(".pg-cursor");
    this.keysEl = el.querySelector(".pg-keys");
    this.playBtn = el.querySelector(".pg-play");
    this.bigPlay = el.querySelector(".pg-big-play");
    this.seekEl = el.querySelector(".pg-seek");
    this.timeEl = el.querySelector(".pg-time");
    this.chapterEl = el.querySelector(".pg-chapter");
    this.rowEls = [];
    for (var r = 0; r < cast.rows; r++) {
      var d = document.createElement("div");
      d.className = "pg-row";
      this.rowsEl.appendChild(d);
      this.rowEls.push(d);
    }
    this.rowsEl.style.width = cast.cols + "ch";

    // exercise ticks on the track
    var ticks = el.querySelector(".pg-ticks");
    cast.markers.forEach(function (m) {
      var tk = document.createElement("span");
      tk.style.left = (100 * m.t) / cast.duration + "%";
      tk.title = m.label;
      ticks.appendChild(tk);
    });

    this.playBtn.addEventListener("click", function () {
      self.toggle();
    });
    this.bigPlay.addEventListener("click", function () {
      self.play();
    });
    this.rowsEl.addEventListener("click", function () {
      // a click that selects text doesn't toggle
      var sel = window.getSelection && window.getSelection();
      if (!sel || sel.isCollapsed) self.toggle();
    });
    el.querySelector(".pg-prev").addEventListener("click", function () {
      self.chapter(-1);
    });
    el.querySelector(".pg-next").addEventListener("click", function () {
      self.chapter(1);
    });
    this.seekEl.addEventListener("input", function () {
      self.seek(parseFloat(self.seekEl.value));
    });
    el.querySelector(".pg-speed").addEventListener("change", function (e) {
      self.setSpeed(parseFloat(e.target.value));
    });
    var copyBtn = el.querySelector(".pg-copy");
    copyBtn.addEventListener("click", function () {
      var text = self.term.grid.map(rowText).join("\n").replace(/\n+$/, "\n");
      var done = function () {
        copyBtn.textContent = "Copied";
        setTimeout(function () {
          copyBtn.textContent = "Copy";
        }, 1200);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, function () {});
    });
    el.addEventListener("keydown", function (e) {
      if (e.target.tagName === "SELECT" || e.ctrlKey || e.metaKey || e.altKey) return;
      if (e.target.tagName === "INPUT" && (e.key === "ArrowLeft" || e.key === "ArrowRight")) return;
      if (e.key === " " || e.key === "k") self.toggle();
      else if (e.key === "ArrowLeft") self.seek(self.t - 5);
      else if (e.key === "ArrowRight") self.seek(self.t + 5);
      else if (e.key === "[") self.chapter(-1);
      else if (e.key === "]") self.chapter(1);
      else return;
      e.preventDefault();
    });

    this.fit();
    if (window.ResizeObserver) {
      new ResizeObserver(function () {
        self.fit();
      }).observe(el);
    } else {
      window.addEventListener("resize", function () {
        self.fit();
      });
    }
    // the first screen as the poster
    this.seek(0);
  }

  // The font size that fits the columns in the width (from 7px up to 18px).
  var charRatio = null;
  function measureRatio(el) {
    if (charRatio) return charRatio;
    var probe = document.createElement("span");
    probe.className = "pg-probe";
    probe.textContent = "MMMMMMMMMM";
    el.appendChild(probe);
    charRatio = probe.getBoundingClientRect().width / 1000 || 0.6;
    el.removeChild(probe);
    return charRatio;
  }

  Player.prototype.fit = function () {
    var width = this.el.clientWidth - 2 * 10;
    if (width <= 0) return;
    var ratio = measureRatio(this.screen);
    var size = Math.max(7, Math.min(18, width / (this.cast.cols * ratio)));
    this.screen.style.fontSize = size.toFixed(2) + "px";
  };

  Player.prototype.apply = function (upTo) {
    var ev = this.cast.events;
    while (this.next < ev.length && ev[this.next][0] <= upTo) {
      var e = ev[this.next];
      if (e[1] === "o") this.term.write(e[2]);
      this.next++;
    }
  };

  Player.prototype.render = function () {
    var term = this.term;
    for (var r = 0; r < term.rows; r++) {
      if (term.dirty[r]) {
        this.rowEls[r].innerHTML = rowHTML(term.grid[r]) || " ";
        term.dirty[r] = false;
      }
    }
    var c = this.cursorEl;
    c.hidden = !term.cursorShown;
    c.style.left = term.col + "ch";
    c.style.top = term.row * 1.25 + "em";
    c.className = "pg-cursor pg-shape-" + term.shape;
    var under = term.grid[term.row] && term.grid[term.row][term.col];
    c.textContent = term.shape <= 2 && under ? under[0] || " " : "";

    var keys = recentKeys(this.cast.inputs, this.t);
    var html = keys
      .map(function (g) {
        return g.typed ? '<span class="pg-typed">' + esc(g.text) + "</span>" : "<kbd>" + esc(g.text) + "</kbd>";
      })
      .join(" ");
    if (this.keysEl._html !== html) {
      this.keysEl.innerHTML = html;
      this.keysEl._html = html;
      this.keysEl.hidden = !html;
    }

    this.seekEl.value = this.t;
    this.timeEl.textContent = fmtTime(this.t);
    var m = this.currentMarker();
    var label = m ? m.label : "";
    if (this.chapterEl.textContent !== label) {
      this.chapterEl.textContent = label;
      var items = this.section.querySelectorAll(".pg-steps > li");
      for (var i = 0; i < items.length; i++) {
        items[i].classList.toggle("pg-current", items[i].getAttribute("data-marker") === label);
      }
    }
    var icon = this.playing ? ICON_PAUSE : ICON_PLAY;
    if (this.playBtn._playing !== this.playing) {
      this.playBtn.innerHTML = icon;
      this.playBtn.setAttribute("aria-label", this.playing ? "Pause" : "Play");
      this.playBtn._playing = this.playing;
    }
    this.bigPlay.hidden = this.playing || this.started;
  };

  Player.prototype.currentMarker = function () {
    var ms = this.cast.markers;
    var cur = null;
    for (var i = 0; i < ms.length && ms[i].t <= this.t + 1e-6; i++) cur = ms[i];
    return cur;
  };

  Player.prototype.seek = function (t) {
    t = Math.max(0, Math.min(t, this.cast.duration));
    if (t < this.t || this.next === 0) {
      this.term.reset();
      this.next = 0;
    }
    this.t = t;
    this.apply(t);
    if (this.playing) {
      this.wallStart = performance.now();
      this.tStart = t;
    }
    this.render();
  };

  Player.prototype.play = function () {
    if (this.playing) return;
    if (this.t >= this.cast.duration - 0.01) this.seek(0);
    this.playing = true;
    this.started = true;
    this.wallStart = performance.now();
    this.tStart = this.t;
    var self = this;
    var tick = function () {
      if (!self.playing) return;
      var t = self.tStart + ((performance.now() - self.wallStart) / 1000) * self.speed;
      if (t >= self.cast.duration) {
        t = self.cast.duration;
        self.playing = false;
      }
      self.t = t;
      self.apply(t);
      self.render();
      if (self.playing) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
    this.render();
  };

  Player.prototype.pause = function () {
    this.playing = false;
    this.render();
  };

  Player.prototype.toggle = function () {
    if (this.playing) this.pause();
    else this.play();
  };

  Player.prototype.setSpeed = function (s) {
    if (this.playing) {
      this.tStart = this.t;
      this.wallStart = performance.now();
    }
    this.speed = s;
  };

  Player.prototype.chapter = function (dir) {
    var ms = this.cast.markers;
    var cur = -1;
    for (var i = 0; i < ms.length && ms[i].t <= this.t + 0.3; i++) cur = i;
    // "previous" restarts the current exercise unless it has just begun
    if (dir < 0 && cur >= 0 && this.t - ms[cur].t > 1.5) dir = 0;
    var k = Math.max(0, Math.min(ms.length - 1, cur + dir));
    if (ms[k]) this.seek(ms[k].t);
  };

  Player.prototype.jumpTo = function (label) {
    var ms = this.cast.markers;
    for (var i = 0; i < ms.length; i++) {
      if (ms[i].label === label) {
        this.seek(ms[i].t);
        this.play();
        return;
      }
    }
  };

  // Lessons and tabs ---------------------------------------------------------
  var players = {};
  function openLesson(section) {
    var name = section.getAttribute("data-lesson");
    if (players[name] !== undefined) return;
    players[name] = null;
    var el = section.querySelector(".pg-player");
    el.classList.add("pg-loading");
    load(name, section.getAttribute("data-src"), function (cast) {
      el.classList.remove("pg-loading");
      if (!cast) {
        el.innerHTML = '<p class="pg-error">The recording could not be loaded.</p>';
        return;
      }
      players[name] = new Player(el, cast, section);
    });
  }

  var sections = document.querySelectorAll(".pg-lesson");
  var tabs = document.querySelectorAll('.pg-tabs [role="tab"]');
  function selectTab(tab, focus) {
    for (var i = 0; i < tabs.length; i++) {
      var on = tabs[i] === tab;
      tabs[i].setAttribute("aria-selected", on ? "true" : "false");
      tabs[i].tabIndex = on ? 0 : -1;
      var panel = document.getElementById(tabs[i].getAttribute("aria-controls"));
      if (panel) {
        panel.hidden = !on;
        if (on) openLesson(panel);
        else {
          var p = players[panel.getAttribute("data-lesson")];
          if (p) p.pause();
        }
      }
    }
    if (focus) tab.focus();
    try {
      history.replaceState(null, "", "#" + tab.id.replace(/^tab-/, ""));
    } catch (e) {}
  }
  for (var i = 0; i < tabs.length; i++) {
    tabs[i].addEventListener("click", function (e) {
      selectTab(e.currentTarget);
    });
    tabs[i].addEventListener("keydown", function (e) {
      var list = Array.prototype.slice.call(tabs);
      var k = list.indexOf(e.currentTarget);
      if (e.key === "ArrowRight") selectTab(list[(k + 1) % list.length], true);
      else if (e.key === "ArrowLeft") selectTab(list[(k - 1 + list.length) % list.length], true);
      else return;
      e.preventDefault();
    });
  }
  for (var s = 0; s < sections.length; s++) {
    (function (section) {
      section.addEventListener("click", function (e) {
        var btn = e.target.closest(".pg-jump");
        if (!btn) return;
        var li = btn.closest("li");
        var p = players[section.getAttribute("data-lesson")];
        if (p && li) {
          p.jumpTo(li.getAttribute("data-marker"));
          section.querySelector(".pg-player").scrollIntoView({ block: "nearest", behavior: "smooth" });
          section.querySelector(".pg-player").focus({ preventScroll: true });
        }
      });
    })(sections[s]);
  }
  // #workflow opens that lesson
  var hashTab = location.hash && document.getElementById("tab-" + location.hash.slice(1));
  if (hashTab) selectTab(hashTab);
  else if (tabs.length) selectTab(tabs[0]);

  // Try the syntax -----------------------------------------------------------
  // A few of org.nvim's highlight rules, enough to see what Org text looks
  // like: headlines (by level), TODO keywords, priorities, tags, planning
  // lines, timestamps, lists and checkboxes, tables, #+ keywords, blocks,
  // comments, links and emphasis.
  var TODO = /^(TODO|NEXT|WAITING|HOLD|DONE|CANCELLED|CANCELED)$/;
  var INLINE = new RegExp(
    [
      "(\\[\\[[^\\]]*\\](?:\\[[^\\]]*\\])?\\])", // 1 link
      "([<\\[]\\d{4}-\\d{2}-\\d{2}(?: [A-Za-z]{2,3}\\.?)?(?: \\d{1,2}:\\d{2}(?:-\\d{1,2}:\\d{2})?)?(?: [.+]?\\+\\d+[hdwmy])?[>\\]])", // 2 timestamp
      "(\\b(?:SCHEDULED|DEADLINE|CLOSED):)", // 3 planning keyword
      "(^|[\\s('\"{])([*/_=~+])(\\S|\\S.*?\\S)\\5(?=$|[\\s.,;:!?'\")}\\]-])", // 4 before, 5 marker, 6 body
      "(\\[\\d*/\\d*\\]|\\[\\d*%\\])", // 7 statistics cookie
    ].join("|"),
    "g"
  );
  var EMPHASIS = { "*": "o-b", "/": "o-i", _: "o-u", "=": "o-v", "~": "o-c", "+": "o-s" };
  function span(cls, text) {
    return '<span class="' + cls + '">' + esc(text) + "</span>";
  }
  function inline(s) {
    var out = "";
    var last = 0;
    var m;
    INLINE.lastIndex = 0;
    while ((m = INLINE.exec(s))) {
      out += esc(s.slice(last, m.index));
      if (m[1]) out += span("o-link", m[0]);
      else if (m[2]) out += span("o-date", m[0]);
      else if (m[3]) out += span("o-plan", m[0]);
      else if (m[5]) out += esc(m[4]) + span(EMPHASIS[m[5]], m[5] + m[6] + m[5]);
      else if (m[7]) out += span("o-cookie", m[0]);
      last = m.index + m[0].length;
      if (!m[0].length) INLINE.lastIndex++;
    }
    return out + esc(s.slice(last));
  }

  function highlightLine(line) {
    var h = line.match(/^(\*+)(\s+)(.*)$/);
    if (h) {
      var level = h[1].length;
      var rest = h[3];
      var out = '<span class="o-stars">' + h[1] + "</span>" + h[2];
      var words = rest.match(/^(\S+)(\s+)(.*)$/);
      if (words && TODO.test(words[1])) {
        out += '<span class="o-' + (/^(DONE|CANCELL?ED)$/.test(words[1]) ? "done" : "todo") + '">' + words[1] + "</span>" + words[2];
        rest = words[3];
      }
      var pri = rest.match(/^(\[#[A-Z0-9]\])(\s*)(.*)$/);
      if (pri) {
        out += '<span class="o-pri">' + pri[1] + "</span>" + pri[2];
        rest = pri[3];
      }
      var tags = rest.match(/^(.*?)(\s+)(:[\w@#%:]+:)\s*$/);
      var title = tags ? tags[1] : rest;
      out += '<span class="o-h o-h' + (((level - 1) % 4) + 1) + '">' + inline(title) + "</span>";
      if (tags) out += tags[2] + '<span class="o-tag">' + esc(tags[3]) + "</span>";
      return out;
    }
    if (/^\s*\|/.test(line)) return '<span class="o-table">' + esc(line) + "</span>";
    if (/^\s*#\+(begin|end)_/i.test(line)) return '<span class="o-block">' + esc(line) + "</span>";
    var kw = line.match(/^(\s*#\+\w+:)(.*)$/);
    if (kw) return '<span class="o-kw">' + esc(kw[1]) + "</span>" + '<span class="o-kwv">' + esc(kw[2]) + "</span>";
    if (/^\s*#(\s|$)/.test(line)) return '<span class="o-comment">' + esc(line) + "</span>";
    if (/^\s*:\w+:\s*$/.test(line) || /^\s*:END:\s*$/.test(line)) return '<span class="o-drawer">' + esc(line) + "</span>";
    var li = line.match(/^(\s*)([-+]|\d+[.)])(\s+)(\[[ X-]\]\s)?(.*)$/);
    if (li) {
      var box = li[4] ? '<span class="o-box' + (li[4][1] === "X" ? " o-box-on" : "") + '">' + li[4] + "</span>" : "";
      return li[1] + '<span class="o-bullet">' + li[2] + "</span>" + li[3] + box + inline(li[5]);
    }
    return inline(line);
  }

  var tryBox = document.querySelector(".pg-try");
  if (tryBox) {
    var input = tryBox.querySelector("textarea");
    var hl = tryBox.querySelector(".pg-try-hl");
    var update = function () {
      // a trailing newline keeps the last (empty) line's height
      hl.innerHTML = input.value.split("\n").map(highlightLine).join("\n") + "\n";
      hl.scrollTop = input.scrollTop;
      hl.scrollLeft = input.scrollLeft;
    };
    input.addEventListener("input", update);
    input.addEventListener("scroll", function () {
      hl.scrollTop = input.scrollTop;
      hl.scrollLeft = input.scrollLeft;
    });
    tryBox.classList.add("pg-try-ready");
    update();
  }
})();
