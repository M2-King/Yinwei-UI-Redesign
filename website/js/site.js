(() => {
  const nav = document.getElementById("nav-links");
  const toggle = document.querySelector(".nav-toggle");
  if (toggle && nav) {
    toggle.addEventListener("click", () => {
      const open = nav.classList.toggle("open");
      toggle.setAttribute("aria-expanded", String(open));
    });
    nav.querySelectorAll("a").forEach((link) => {
      link.addEventListener("click", () => {
        nav.classList.remove("open");
        toggle.setAttribute("aria-expanded", "false");
      });
    });
  }

  const ua = navigator.userAgent;
  let platform = "windows";
  if (/Android/i.test(ua)) platform = "android";
  else if (/iPhone|iPad|iPod/i.test(ua)) platform = "ios";
  else if (/Mac OS X|Macintosh/i.test(ua)) platform = "macos";
  else if (/Win/i.test(ua)) platform = "windows";
  document.querySelectorAll("[data-platform]").forEach((card) => {
    if (card.getAttribute("data-platform") === platform) {
      card.classList.add("highlight");
    }
  });

  const apk = document.getElementById("apk-download");
  if (
    apk &&
    apk.dataset.cdn &&
    !/^(localhost|127\.0\.0\.1)$/.test(location.hostname)
  ) {
    apk.href = apk.dataset.cdn;
  }

  const az = document.getElementById("az");
  const el = document.getElementById("el");
  const dist = document.getElementById("dist");
  const azVal = document.getElementById("az-val");
  const elVal = document.getElementById("el-val");
  const distVal = document.getElementById("dist-val");
  const dot = document.getElementById("source-dot");

  const render = () => {
    if (!az || !el || !dist || !dot) return;
    const azimuth = Number(az.value);
    const elevation = Number(el.value);
    const distance = Number(dist.value) / 10;
    azVal.textContent = `${azimuth}°`;
    elVal.textContent = `${elevation}°`;
    distVal.textContent = `${distance.toFixed(1)} m`;
    const radius = 36 + distance * 14;
    const rad = ((azimuth - 90) * Math.PI) / 180;
    const lift = elevation * 0.45;
    dot.setAttribute("cx", String(110 + Math.cos(rad) * radius));
    dot.setAttribute("cy", String(110 + Math.sin(rad) * radius - lift));
    dot.setAttribute("r", String(5.5 + distance * 0.4));
  };

  [az, el, dist].forEach((input) => input && input.addEventListener("input", render));
  render();
})();
