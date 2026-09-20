// Composer keyboard behavior for the messenger: Enter sends, Shift+Enter
// inserts a newline (a plain <textarea>'s only default is "always newline",
// so sending on Enter has to be done here). When the @mention dropdown is
// open (server-rendered, see ComposerComponent), Up/Down/Enter drive it
// instead of the textarea, so picking a suggestion can never race with
// sending the raw "@partial" text.
export const MessengerHooks = {};

MessengerHooks.ComposerKeydown = {
  mounted() {
    this.handleKeydown = (event) => {
      const suggestionsOpen = this.el.dataset.suggestionsOpen === "true";

      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        if (!suggestionsOpen) return;

        event.preventDefault();
        this.pushEventTo(this.el.form, "move_highlight", {
          direction: event.key === "ArrowDown" ? "down" : "up",
        });
        return;
      }

      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();

        if (suggestionsOpen) {
          this.pushEventTo(this.el.form, "select_highlighted_mention", {});
        } else {
          this.el.form.requestSubmit();
        }
      }
    };

    this.el.addEventListener("keydown", this.handleKeydown);
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.handleKeydown);
  },
};
