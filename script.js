const yearNode = document.getElementById("year");

if (yearNode) {
  yearNode.textContent = String(new Date().getFullYear());
}

const desktopDemo = document.querySelector("[data-desktop-demo]");

if (desktopDemo) {
  window.setTimeout(() => {
    desktopDemo.classList.remove("is-collapsed");
    desktopDemo.classList.add("is-expanded");
  }, 3000);
}

const githubRepoApiUrl = "https://api.github.com/repos/erha19/ping-island";
const starCacheKey = "ping-island-stars";
const starCacheMaxAge = 1000 * 60 * 30;
const starNodes = Array.from(document.querySelectorAll("[data-stars]"));

function formatStars(stars) {
  return new Intl.NumberFormat("en", {
    notation: stars >= 10000 ? "compact" : "standard",
    maximumFractionDigits: 1
  }).format(stars);
}

function setStarCount(stars, source = "GitHub") {
  if (!Number.isFinite(stars) || stars < 0) return;

  const label = formatStars(stars);

  starNodes.forEach((node) => {
    node.textContent = label;
    node.classList.remove("is-loading");
    node.title = `${stars.toLocaleString("en")} stars on ${source}`;
  });
}

function readCachedStars() {
  try {
    const cached = JSON.parse(window.localStorage.getItem(starCacheKey) || "null");

    if (
      cached &&
      Number.isFinite(cached.stars) &&
      Number.isFinite(cached.updatedAt) &&
      Date.now() - cached.updatedAt < starCacheMaxAge
    ) {
      return cached.stars;
    }
  } catch {
    try {
      window.localStorage.removeItem(starCacheKey);
    } catch {
      // Ignore storage cleanup failures.
    }
  }

  return null;
}

function writeCachedStars(stars) {
  try {
    window.localStorage.setItem(
      starCacheKey,
      JSON.stringify({
        stars,
        updatedAt: Date.now()
      })
    );
  } catch {
    // Ignore storage failures; the live GitHub response already updated the page.
  }
}

async function refreshStars() {
  if (starNodes.length === 0) return;

  const cachedStars = readCachedStars();

  if (cachedStars !== null) {
    setStarCount(cachedStars, "cached GitHub data");
  }

  try {
    const response = await fetch(githubRepoApiUrl, {
      cache: "no-store",
      headers: {
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"
      }
    });

    if (!response.ok) {
      throw new Error(`GitHub API returned ${response.status}`);
    }

    const repo = await response.json();
    const stars = typeof repo.stargazers_count === "number" ? repo.stargazers_count : null;

    if (stars === null) {
      throw new Error("GitHub API response did not include stargazers_count");
    }

    setStarCount(stars);
    writeCachedStars(stars);
  } catch {
    if (cachedStars === null) {
      starNodes.forEach((node) => {
        node.textContent = "--";
        node.classList.remove("is-loading");
        node.title = "GitHub star count is temporarily unavailable";
      });
    }
  }
}

refreshStars();

const choiceGrid = document.querySelector(".desktop-demo-choice-grid");
const submitBtn = document.querySelector(".desktop-demo-submit");
const confettiColors = ["#fff3d9", "#ffd86b", "#ffb05c", "#ff7a59", "#ffe6f4"];
let submitCelebrateTimeout = null;
const detachedPetImages = Array.from(document.querySelectorAll(".detached-header-icon, .floating-pet-image"));
const detachedPetSources = [
  { src: "./assets/mascots/claude.gif", alt: "Claude Code Buddy" },
  { src: "./assets/mascots/codex.gif", alt: "Codex Buddy" },
  { src: "./assets/mascots/gemini.gif", alt: "Gemini CLI Buddy" },
  { src: "./assets/mascots/hermes.gif", alt: "Hermes Agent Buddy" },
  { src: "./assets/mascots/qwen.gif", alt: "Qwen Code Buddy" },
  { src: "./assets/mascots/openclaw.gif", alt: "OpenClaw Buddy" },
  { src: "./assets/mascots/opencode.gif", alt: "OpenCode Buddy" },
  { src: "./assets/mascots/cursor.gif", alt: "Cursor Buddy" },
  { src: "./assets/mascots/trae.gif", alt: "Trae Buddy" },
  { src: "./assets/mascots/qoder.gif", alt: "Qoder Buddy" },
  { src: "./assets/mascots/codebuddy.gif", alt: "CodeBuddy Buddy" },
  { src: "./assets/mascots/copilot.gif", alt: "GitHub Copilot Buddy" }
];

function setSubmitReady(isReady) {
  if (!submitBtn) return;

  submitBtn.classList.toggle("is-ready", isReady);
  submitBtn.disabled = !isReady;
  submitBtn.setAttribute("aria-disabled", String(!isReady));
}

function triggerSubmitConfetti(button) {
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  const rect = button.getBoundingClientRect();
  const originX = rect.left + rect.width / 2;
  const originY = rect.top + rect.height / 2;
  const confettiLayer = document.createElement("div");

  confettiLayer.className = "desktop-demo-confetti";

  for (let index = 0; index < 18; index += 1) {
    const particle = document.createElement("span");
    const angle = (-90 + (160 / 17) * index + (Math.random() * 18 - 9)) * (Math.PI / 180);
    const distance = 52 + Math.random() * 40;
    const drift = Math.random() * 22 - 11;

    particle.className = "desktop-demo-confetti-piece";
    if (index % 3 === 0) {
      particle.classList.add("is-dot");
    }

    particle.style.setProperty("--origin-x", `${originX}px`);
    particle.style.setProperty("--origin-y", `${originY}px`);
    particle.style.setProperty("--travel-x", `${Math.cos(angle) * distance}px`);
    particle.style.setProperty("--travel-y", `${Math.sin(angle) * distance - 18}px`);
    particle.style.setProperty("--spin", `${drift + (Math.random() > 0.5 ? 1 : -1) * (180 + Math.random() * 140)}deg`);
    particle.style.setProperty("--confetti-color", confettiColors[index % confettiColors.length]);
    particle.style.animationDelay = `${Math.random() * 90}ms`;
    particle.style.opacity = "0";
    confettiLayer.appendChild(particle);
  }

  document.body.appendChild(confettiLayer);
  window.setTimeout(() => confettiLayer.remove(), 1100);
}

if (choiceGrid && submitBtn) {
  setSubmitReady(false);

  choiceGrid.addEventListener("click", (e) => {
    const choice = e.target.closest(".desktop-demo-choice");
    if (!choice) return;

    choiceGrid.querySelectorAll(".desktop-demo-choice").forEach((c) => c.classList.remove("is-active"));
    choice.classList.add("is-active");
    setSubmitReady(true);
  });

  submitBtn.addEventListener("click", () => {
    if (submitBtn.disabled) return;

    submitBtn.classList.remove("is-celebrating");
    void submitBtn.offsetWidth;
    submitBtn.classList.add("is-celebrating");

    if (submitCelebrateTimeout) {
      window.clearTimeout(submitCelebrateTimeout);
    }

    submitCelebrateTimeout = window.setTimeout(() => {
      submitBtn.classList.remove("is-celebrating");
    }, 540);

    triggerSubmitConfetti(submitBtn);
  });
}

if (detachedPetImages.length > 0 && detachedPetSources.length > 1) {
  let detachedPetIndex = 0;

  window.setInterval(() => {
    detachedPetIndex = (detachedPetIndex + 1) % detachedPetSources.length;
    const nextPet = detachedPetSources[detachedPetIndex];

    detachedPetImages.forEach((image) => {
      image.src = nextPet.src;
      image.alt = nextPet.alt;
    });
  }, 5000);
}
