/**
 * Styles for the injected overlay, kept as a string so they can be adopted into
 * a shadow root. Everything is scoped inside `:host`, and no rule leaks to the
 * page — this is why Instagram's global CSS cannot reshape our button and why
 * our reset cannot break their layout.
 */
export const OVERLAY_CSS = `
:host {
  all: initial;
  --duck-bg: rgba(17, 17, 20, 0.82);
  --duck-fg: #ffffff;
  --duck-accent: #ffc531;
  --duck-radius: 12px;
  --duck-shadow: 0 6px 20px rgba(0, 0, 0, 0.35);
  font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
}

/*
 * The root is sized and positioned to cover the anchor exactly (see
 * Overlay.reposition), so placement is a matter of where the button sits
 * *inside* that box — not of offsets on the box itself. Offsets here would be
 * overridden by the inline top/left/width/height anyway, which is how the
 * button once ended up centred on the left edge.
 */
.duck-root {
  position: absolute;
  z-index: 2147483000;
  pointer-events: none;
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 12px;
  box-sizing: border-box;
  /* Never let the overlay stretch an anchor that has no size of its own. */
  overflow: hidden;
}

/* Column layout: justify-content is vertical, align-items is horizontal. */
.duck-root[data-placement="top-right"] {
  justify-content: flex-start;
  align-items: flex-end;
}
.duck-root[data-placement="bottom-right"] {
  justify-content: flex-end;
  align-items: flex-end;
}
.duck-root[data-placement="bottom-left"] {
  justify-content: flex-end;
  align-items: flex-start;
}

.duck-button {
  pointer-events: auto;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 8px 12px;
  border: none;
  border-radius: var(--duck-radius);
  background: var(--duck-bg);
  color: var(--duck-fg);
  font-size: 13px;
  font-weight: 600;
  line-height: 1;
  cursor: pointer;
  box-shadow: var(--duck-shadow);
  backdrop-filter: blur(12px);
  -webkit-backdrop-filter: blur(12px);
  opacity: 0;
  transform: translateY(-4px);
  transition: opacity 140ms ease, transform 140ms ease, background 140ms ease;
}

/* Idle until the user looks at the media — an always-on button covering the
   frame is the fastest way to get uninstalled. */
.duck-root.is-visible .duck-button { opacity: 0.92; transform: translateY(0); }
.duck-button:hover { opacity: 1; background: rgba(30, 30, 34, 0.94); }
.duck-button:focus-visible { outline: 2px solid var(--duck-accent); outline-offset: 2px; }
.duck-button[disabled] { cursor: progress; opacity: 0.6; }

/* Reads as information rather than an action, because it is not one. */
.duck-button.is-protected { cursor: help; color: #b9b9c4; }
.duck-button.is-protected:hover { background: var(--duck-bg); }

.duck-button svg { width: 15px; height: 15px; flex: none; }

.duck-spinner {
  width: 13px;
  height: 13px;
  border: 2px solid rgba(255, 255, 255, 0.28);
  border-top-color: var(--duck-accent);
  border-radius: 50%;
  animation: duck-spin 700ms linear infinite;
}

@keyframes duck-spin { to { transform: rotate(360deg); } }

.duck-toast {
  pointer-events: auto;
  padding: 8px 12px;
  border-radius: var(--duck-radius);
  background: var(--duck-bg);
  color: var(--duck-fg);
  font-size: 12px;
  box-shadow: var(--duck-shadow);
  max-width: 260px;
}

.duck-toast[data-tone="error"] { border-left: 3px solid #ff6b6b; }

@media (prefers-reduced-motion: reduce) {
  .duck-button, .duck-spinner { transition: none; animation: none; }
}
`;
