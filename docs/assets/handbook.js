/* tuiter handbook — theme, progress, TOC spy, copy buttons, anchors */
(function () {
    "use strict";

    var root = document.documentElement;

    /* ---------- Theme toggle ---------- */
    var toggle = document.getElementById("theme-toggle");

    function currentTheme() {
        return root.getAttribute("data-theme") === "dark" ? "dark" : "light";
    }

    function applyTheme(theme) {
        root.setAttribute("data-theme", theme);
        if (toggle) toggle.setAttribute("aria-checked", theme === "dark" ? "true" : "false");
        try { localStorage.setItem("tuiter-theme", theme); } catch (e) { /* private mode */ }
    }

    // Sync switch state with the theme set by the pre-paint inline script.
    if (toggle) {
        toggle.setAttribute("aria-checked", currentTheme() === "dark" ? "true" : "false");
        toggle.addEventListener("click", function () {
            applyTheme(currentTheme() === "dark" ? "light" : "dark");
        });
    }

    /* ---------- Reading progress ---------- */
    var bar = document.getElementById("progress-bar");
    var ticking = false;
    function updateProgress() {
        ticking = false;
        if (!bar) return;
        var max = document.documentElement.scrollHeight - window.innerHeight;
        var ratio = max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
        bar.style.transform = "scaleX(" + ratio.toFixed(4) + ")";
    }
    window.addEventListener("scroll", function () {
        if (!ticking) { ticking = true; window.requestAnimationFrame(updateProgress); }
    }, { passive: true });
    updateProgress();

    /* ---------- Section anchors (§ link on hover) ---------- */
    document.querySelectorAll(".section h2[id], section[id] > h2").forEach(function (h) {
        var section = h.closest("section[id]");
        if (!section || h.querySelector(".anchor")) return;
        var a = document.createElement("a");
        a.className = "anchor";
        a.href = "#" + section.id;
        a.setAttribute("aria-label", "Link to this section");
        a.textContent = "#";
        h.appendChild(a);
    });

    /* ---------- TOC scroll-spy ---------- */
    var links = Array.prototype.slice.call(document.querySelectorAll(".toc-list a"));
    var byId = {};
    links.forEach(function (a) {
        var id = a.getAttribute("href").slice(1);
        byId[id] = a;
    });
    if ("IntersectionObserver" in window) {
        var active = null;
        var spy = new IntersectionObserver(function (entries) {
            entries.forEach(function (entry) {
                if (!entry.isIntersecting) return;
                var id = entry.target.id;
                if (!byId[id] || active === byId[id]) return;
                if (active) active.removeAttribute("aria-current");
                active = byId[id];
                active.setAttribute("aria-current", "true");
            });
        }, { rootMargin: "-20% 0px -70% 0px" });
        document.querySelectorAll("main section[id]").forEach(function (s) { spy.observe(s); });
    }

    /* ---------- Copy buttons on code figures ---------- */
    document.querySelectorAll(".code-fig").forEach(function (fig) {
        var head = fig.querySelector(".code-head");
        var pre = fig.querySelector("pre code");
        if (!head || !pre) return;
        var btn = document.createElement("button");
        btn.type = "button";
        btn.className = "copy-btn";
        btn.textContent = "Copy";
        btn.setAttribute("aria-label", "Copy code to clipboard");
        btn.addEventListener("click", function () {
            var done = function (ok) {
                btn.textContent = ok ? "Copied" : "Failed";
                btn.classList.toggle("copied", ok);
                window.setTimeout(function () {
                    btn.textContent = "Copy";
                    btn.classList.remove("copied");
                }, 1600);
            };
            var text = pre.innerText || pre.textContent;
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(false); });
            } else {
                var ta = document.createElement("textarea");
                ta.value = text;
                ta.setAttribute("readonly", "");
                ta.style.position = "absolute";
                ta.style.left = "-9999px";
                document.body.appendChild(ta);
                ta.select();
                try { done(document.execCommand("copy")); }
                catch (e) { done(false); }
                document.body.removeChild(ta);
            }
        });
        head.appendChild(btn);
    });
})();
