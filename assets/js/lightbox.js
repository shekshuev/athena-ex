// Click-to-preview lightbox for read-only content images - block-based
// `:image` blocks and read-only TipTap-rendered images alike, both marked
// with `.js-lightbox-img`.
//
// The overlay is built lazily and appended to `document.body`, *outside* the
// DOM LiveView patches. It used to be a `<dialog class="modal">` rendered by
// the dashboard layout, which had two problems: morphdom could move a node
// the browser had promoted to the top layer, and - the one students actually
// hit - the only way to close it was a click landing exactly on the dialog
// element. Clicking the image toggles it to natural size, at which point the
// scroll container filled the viewport and every subsequent click landed on
// the image or the container instead, so the overlay looked like a dead,
// unclickable layer over the player with a page reload as the only way out.
//
// Hence four independent ways out, none of which can be covered up by the
// image: the always-visible close button (fixed to the viewport corner, above
// the image), a click on the overlay background, Escape, and any navigation.
//
// Clicking the image itself still toggles between fit-to-viewport and natural
// size (`.lightbox--zoomed`), which is what the enlarged view is for.
// `touch-manipulation` on both this image and the thumbnails suppresses the
// browser's own double-tap-to-zoom, which would otherwise fight the toggle and
// zoom the whole page instead of just the picture (most noticeable on a
// tablet/touch laptop, e.g. an instructor QA-ing a course in the builder's
// test run) - the open overlay visually "disappearing" was the page itself
// having been zoomed/panned out from under it, not an actual close.

const CLOSE_ICON = '<span class="hero-x-mark size-6"></span>';

let overlay = null;
let image = null;

const isOpen = () => !!overlay && overlay.classList.contains("lightbox--open");

const onKeyDown = (e) => {
  if (e.key === "Escape" && isOpen()) {
    e.preventDefault();
    e.stopPropagation();
    close();
  }
};

const build = () => {
  overlay = document.createElement("div");
  overlay.className = "lightbox";
  overlay.setAttribute("role", "dialog");
  overlay.setAttribute("aria-modal", "true");

  image = document.createElement("img");
  image.className = "lightbox__img";
  image.alt = "";

  const closeBtn = document.createElement("button");
  closeBtn.type = "button";
  closeBtn.className = "lightbox__close";
  closeBtn.innerHTML = CLOSE_ICON;
  closeBtn.setAttribute("aria-label", "Close");

  closeBtn.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();
    close();
  });

  // Only a click on the background itself closes; a click on the image is a
  // zoom toggle, and `stopPropagation` there would hide it from this listener.
  overlay.addEventListener("click", (e) => {
    if (e.target === image) {
      overlay.classList.toggle("lightbox--zoomed");
      return;
    }

    close();
  });

  overlay.append(image, closeBtn);
  document.body.appendChild(overlay);
};

const open = (src, alt) => {
  if (!overlay) build();

  image.src = src;
  image.alt = alt || "";
  overlay.classList.remove("lightbox--zoomed");
  overlay.classList.add("lightbox--open");
  document.body.classList.add("lightbox-open");

  // Capture phase, so an exam's own key handling can't swallow it first.
  window.addEventListener("keydown", onKeyDown, true);
};

const close = () => {
  if (!overlay) return;

  window.removeEventListener("keydown", onKeyDown, true);
  overlay.classList.remove("lightbox--open", "lightbox--zoomed");
  document.body.classList.remove("lightbox-open");
  // Stops a large image from decoding/animating behind the scenes while closed.
  image.removeAttribute("src");
};

export const initLightbox = () => {
  // Delegated rather than per-hook: TipTap's images live inside a
  // `phx-update="ignore"` container LiveView never re-scans, and delegation
  // means images patched in later work without re-attaching anything.
  document.addEventListener("click", (e) => {
    const img = e.target.closest(".js-lightbox-img");
    if (!img) return;

    open(img.currentSrc || img.src, img.alt);
  });

  // Never leave the overlay stranded over a page it no longer belongs to.
  window.addEventListener("phx:page-loading-start", close);
  window.addEventListener("popstate", close);
  window.addEventListener("pagehide", close);
};
