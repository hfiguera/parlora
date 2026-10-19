// Progressive enhancements only. Reading and navigation never depend on this file.
// No walkthrough or copy events are sent to analytics.
const prose = document.querySelector(".prose");
if (prose && window.Prism) window.Prism.highlightAllUnder(prose);

document.querySelectorAll(".prose pre").forEach((block) => {
  const code = block.querySelector("code");
  if (!code || !navigator.clipboard) return;
  const button = document.createElement("button");
  button.type = "button";
  button.className = "copy-code";
  button.textContent = "Copy";
  button.setAttribute("aria-label", "Copy code");
  const status = document.createElement("span");
  status.className = "sr-only";
  status.setAttribute("role", "status");
  let reset;
  button.addEventListener("click", async () => {
    clearTimeout(reset);
    try {
      await navigator.clipboard.writeText(code.textContent);
      button.textContent = "Copied";
      status.textContent = "Code copied to clipboard.";
    } catch {
      const range = document.createRange();
      range.selectNodeContents(code);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      button.textContent = "Code selected";
      status.textContent = "Clipboard unavailable. Use your browser’s copy command.";
    }
    reset = setTimeout(() => {
      button.textContent = "Copy";
      status.textContent = "";
    }, 2500);
  });
  block.classList.add("has-copy");
  block.append(button, status);
});

document.querySelectorAll(".session-figure").forEach((figure) => {
  const stage = figure.querySelector(".flow-stage");
  const controls = figure.querySelector(".flow-controls");
  const caption = figure.querySelector(".flow-caption");
  const play = figure.querySelector(".flow-play");
  const next = figure.querySelector(".flow-next");
  const label = figure.querySelector(".flow-step");
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
  const steps = [
    ["listen", "Someone speaks through the audio channel. Parlora passes their audio to the voice provider."],
    ["delegate", "The voice provider requests application work. Your application policy determines how that request becomes a backend task."],
    ["work", "Your backend runs the action. Caller audio can continue flowing while the work is in progress."],
    ["result", "The action returns. The application policy and session state determine whether its result is still relevant to deliver."],
    ["speak", "The voice provider generates a spoken response. Its audio returns through Parlora to the caller."],
  ];
  let step = -1;
  let running = false;
  let timer;

  function pause() {
    clearTimeout(timer);
    running = false;
    stage.classList.remove("is-playing");
    play.textContent = step === steps.length - 1 ? "Replay walkthrough" : step < 0 ? "Play walkthrough" : "Continue walkthrough";
  }

  function render() {
    const [name, text] = steps[step];
    stage.dataset.step = name;
    caption.textContent = text;
    label.textContent = `Step ${step + 1} of ${steps.length}`;
    next.textContent = step === steps.length - 1 ? "Start again" : "Next step";
    stage.classList.toggle("is-playing", running && !reduced.matches);
  }

  function advance() {
    step += 1;
    render();
    if (step === steps.length - 1) {
      pause();
    } else {
      timer = setTimeout(advance, 3400);
    }
  }

  play.addEventListener("click", () => {
    if (running) return pause();
    running = true;
    play.textContent = "Pause walkthrough";
    if (step === steps.length - 1) step = -1;
    if (step < 0) advance();
    else {
      render();
      timer = setTimeout(advance, 3400);
    }
  });

  next.addEventListener("click", () => {
    pause();
    step = (step + 1) % steps.length;
    render();
    play.textContent = step === steps.length - 1 ? "Replay walkthrough" : "Continue walkthrough";
  });

  if ("IntersectionObserver" in window) {
    const observer = new IntersectionObserver(([entry]) => {
      if (!entry.isIntersecting && running) pause();
    });
    observer.observe(figure);
  }
  document.addEventListener("visibilitychange", () => {
    if (document.hidden && running) pause();
  });
  reduced.addEventListener("change", () => {
    if (reduced.matches && running) pause();
  });
  controls.hidden = false;
});
