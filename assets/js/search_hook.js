// The ignored controller owns listeners only. LiveView owns the dialog's
// content and result stream; ignore_attributes preserves the native open state.
export const GlobalSearch = {
  mounted() {
    this.connected = true;
    this.dialog = document.getElementById("global-search-dialog");
    this.input = document.getElementById("global-search-input");
    this.results = document.getElementById("global-search-results");
    this.selectedID = null;
    this.lastInput = "";
    this.returnFocus = null;

    this.handleEvent("search:open", () => {
      if (!this.dialog.open) {
        this.returnFocus = document.activeElement;
        this.dialog.showModal();
      }
      this.input.focus({ preventScroll: true });
      this.sync();
    });
    this.handleEvent("search:close", () => this.close());
    this.handleEvent("search:updated", () => this.sync());

    this.onKey = (event) => {
      if (event.isComposing) return;
      if (this.connected && (event.ctrlKey || event.metaKey) && !event.altKey && !event.shiftKey && event.key.toLowerCase() === "k") {
        event.preventDefault();
        event.stopPropagation();
        this.dialog.open ? this.input.focus() : this.pushEvent("open", {});
        return;
      }
      if (!this.dialog.open) return;
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        this.requestClose();
        return;
      }
      if (event.key === "Tab") {
        const focusable = Array.from(this.dialog.querySelectorAll("button:not([disabled]), input:not([disabled]), a[href], [tabindex='0']"))
          .filter((el) => el.getClientRects().length > 0 && getComputedStyle(el).visibility !== "hidden");
        if (focusable.length) {
          event.preventDefault();
          event.stopPropagation();
          const index = focusable.indexOf(document.activeElement);
          const next = (index + (event.shiftKey ? -1 : 1) + focusable.length) % focusable.length;
          focusable[next].focus({ preventScroll: true });
        }
        return;
      }
      if (event.target !== this.input && !event.target.closest("[data-search-result]")) return;
      const links = this.currentLinks();
      if (["ArrowDown", "ArrowUp"].includes(event.key) && links.length) {
        event.preventDefault();
        event.stopPropagation();
        const index = links.findIndex((link) => link.id === this.selectedID);
        const delta = event.key === "ArrowDown" ? 1 : -1;
        const next = index < 0 ? (delta > 0 ? 0 : links.length - 1) : (index + delta + links.length) % links.length;
        this.select(links[next], true);
        this.input.focus({ preventScroll: true });
      } else if (event.key === "Enter" && event.target === this.input && this.selectedID) {
        const selected = links.find((link) => link.id === this.selectedID);
        if (selected) {
          event.preventDefault();
          event.stopPropagation();
          if (event.ctrlKey || event.metaKey) window.open(selected.href, "_blank", "noopener");
          else selected.click();
        }
      }
    };
    this.onInput = () => this.sync();
    this.onCancel = (event) => { event.preventDefault(); this.requestClose(); };
    this.onClick = (event) => {
      if (event.target.closest("#global-search-close")) this.close();
      if (event.target === this.dialog) {
        const rect = this.dialog.getBoundingClientRect();
        if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) {
          this.requestClose();
        }
      }
    };
    this.onFocus = (event) => {
      const link = event.target.closest("[data-search-result]");
      if (link) this.select(link);
    };
    window.addEventListener("keydown", this.onKey, true);
    this.input.addEventListener("input", this.onInput);
    this.dialog.addEventListener("cancel", this.onCancel);
    this.dialog.addEventListener("click", this.onClick);
    this.dialog.addEventListener("focusin", this.onFocus);

    this.observer = new MutationObserver(() => this.sync());
    this.observer.observe(this.results, { childList: true, subtree: true });
    this.observer.observe(this.dialog, { attributes: true, attributeFilter: ["data-query", "data-status"] });

  },

  currentLinks() {
    if (this.input.value !== this.dialog.dataset.query) return [];
    return Array.from(this.results.querySelectorAll("[data-search-result]"));
  },

  sync() {
    if (this.lastInput !== this.input.value) {
      this.selectedID = null;
      this.lastInput = this.input.value;
      this.dialog.querySelector(".search-palette-body").scrollTop = 0;
    }
    this.dialog.dataset.typing = String(this.input.value !== this.dialog.dataset.query);
    const links = this.currentLinks();
    this.select(links.find((link) => link.id === this.selectedID) || links[0]);
    if (this.dialog.open && document.activeElement === document.body) this.input.focus({ preventScroll: true });
  },

  select(link, scroll = false) {
    this.selectedID = link?.id || null;
    this.results.querySelectorAll("[data-search-result]").forEach((item) => {
      item.setAttribute("aria-selected", String(item.id === this.selectedID));
    });
    if (link) {
      this.input.setAttribute("aria-activedescendant", link.id);
      if (scroll) link.scrollIntoView({ block: "nearest" });
    } else this.input.removeAttribute("aria-activedescendant");
  },

  requestClose() {
    this.close();
    if (this.connected) this.pushEvent("close", {});
  },

  close(restoreFocus = true) {
    if (!this.dialog.open) return;
    this.dialog.close();
    if (restoreFocus && this.returnFocus?.isConnected) this.returnFocus.focus({ preventScroll: true });
  },

  disconnected() { this.connected = false; },
  reconnected() { this.connected = true; },

  destroyed() {
    this.connected = false;
    this.observer.disconnect();
    window.removeEventListener("keydown", this.onKey, true);
    this.input.removeEventListener("input", this.onInput);
    this.dialog.removeEventListener("cancel", this.onCancel);
    this.dialog.removeEventListener("click", this.onClick);
    this.dialog.removeEventListener("focusin", this.onFocus);
    this.close(false);
  },
};
