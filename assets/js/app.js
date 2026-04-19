import { Editor } from "@tiptap/core";
import CodeBlockLowlight from "@tiptap/extension-code-block-lowlight";
import Color from "@tiptap/extension-color";
import Details from "@tiptap/extension-details";
import DetailsContent from "@tiptap/extension-details-content";
import DetailsSummary from "@tiptap/extension-details-summary";
import FontFamily from "@tiptap/extension-font-family";
import Highlight from "@tiptap/extension-highlight";
import TiptapImage from "@tiptap/extension-image";
import Link from "@tiptap/extension-link";
import Mathematics from "@tiptap/extension-mathematics";
import Placeholder from "@tiptap/extension-placeholder";
import Subscript from "@tiptap/extension-subscript";
import Superscript from "@tiptap/extension-superscript";
import Table from "@tiptap/extension-table";
import TableCell from "@tiptap/extension-table-cell";
import TableHeader from "@tiptap/extension-table-header";
import TableRow from "@tiptap/extension-table-row";
import TextAlign from "@tiptap/extension-text-align";
import TextStyle from "@tiptap/extension-text-style";
import Underline from "@tiptap/extension-underline";
import StarterKit from "@tiptap/starter-kit";
import { common, createLowlight } from "lowlight";
import { Socket } from "phoenix";
import { hooks as colocatedHooks } from "phoenix-colocated/athena";
import "phoenix_html";
import { LiveSocket } from "phoenix_live_view";
import Sortable from "sortablejs";
import topbar from "../vendor/topbar";
const lowlight = createLowlight(common);

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const Hooks = {};

Hooks.Sortable = {
  mounted() {
    const eventName = this.el.dataset.eventName || "reorder";

    this.sortable = new Sortable(this.el, {
      animation: 150,
      handle: ".drag-handle",
      ghostClass: "bg-base-200",
      onEnd: (evt) => {
        this.pushEvent(eventName, {
          id: evt.item.dataset.id,
          new_index: evt.newIndex,
          old_index: evt.oldIndex,
        });
      },
    });
  },
  destroyed() {
    if (this.sortable) this.sortable.destroy();
  },
};

Hooks.AntiCheat = {
  mounted() {
    this.lastTriggered = 0;

    this.triggerCheat = (reason) => {
      const now = Date.now();
      if (now - this.lastTriggered < 2000) return;

      this.lastTriggered = now;
      this.pushEvent("cheat_detected", { reason: reason });
    };

    this.handleBlur = () => {
      this.triggerCheat("window_blur");
    };

    this.handleVisibilityChange = () => {
      if (document.visibilityState === "hidden") {
        this.triggerCheat("tab_hidden");
      }
    };

    window.addEventListener("blur", this.handleBlur);
    document.addEventListener("visibilitychange", this.handleVisibilityChange);
  },

  destroyed() {
    window.removeEventListener("blur", this.handleBlur);
    document.removeEventListener(
      "visibilitychange",
      this.handleVisibilityChange,
    );
  },
};

Hooks.TiptapEditor = {
  mounted() {
    const hook = this;
    const content = this.el.dataset.content
      ? JSON.parse(this.el.dataset.content)
      : "";
    const blockId = this.el.dataset.id;
    const isReadOnly = this.el.dataset.readonly === "true";
    let timeout;

    const extensions = [
      StarterKit.configure({ codeBlock: false }),
      CodeBlockLowlight.configure({ lowlight }),
      Underline,
      Link.configure({ openOnClick: isReadOnly }),
      TiptapImage.configure({
        inline: false,
        HTMLAttributes: {
          class: "rounded-sm max-h-[500px] shadow-sm my-4 mx-auto",
        },
      }),
      Highlight.configure({ multicolor: true }),
      TextAlign.configure({ types: ["heading", "paragraph"] }),
      Table.configure({ resizable: !isReadOnly }),
      TableRow,
      TableHeader,
      TableCell,
      Placeholder.configure({
        includeChildren: true,
        placeholder: ({ node }) => {
          if (node.type.name === "detailsSummary") {
            return "Spoiler header...";
          }
          return "Type here...";
        },
        emptyEditorClass: "is-editor-empty",
      }),
      TextStyle,
      Color,
      FontFamily,
      Subscript,
      Superscript,
      Mathematics.configure({
        shouldRender: (state, pos, node) => {
          const $pos = state.doc.resolve(pos);
          return (
            node.type.name === "text" && $pos.parent.type.name !== "codeBlock"
          );
        },
      }),
      Details.configure({
        HTMLAttributes: {
          class: "tiptap-details",
        },
      }),
      DetailsSummary.configure({
        HTMLAttributes: {
          class: "tiptap-details-summary",
        },
      }),
      DetailsContent.configure({
        HTMLAttributes: {
          class: "tiptap-details-content",
        },
      }),
    ];

    const updateToolbarState = (editor) => {
      const wrapper = hook.el.closest(".editor-wrapper");
      const toolbar = wrapper ? wrapper.querySelector(".fixed-toolbar") : null;
      if (!toolbar) return;

      const tableControls = toolbar.querySelectorAll(".tiptap-table-control");

      if (tableControls) {
        for (const tableControl of tableControls) {
          if (editor.isActive("table")) {
            tableControl.classList.remove("hidden");
          } else {
            tableControl.classList.add("hidden");
          }
        }
      }

      const fontSelect = toolbar.querySelector('[data-action="font-family"]');
      if (fontSelect) {
        const activeFont = editor.getAttributes("textStyle").fontFamily || "";
        fontSelect.value = activeFont.replace(/['"]/g, "");
      }

      const colorInput = toolbar.querySelector('[data-action="text-color"]');
      if (colorInput) {
        colorInput.value = editor.getAttributes("textStyle").color || "#000000";
      }

      const highlightInput = toolbar.querySelector(
        '[data-action="highlight-color"]',
      );
      if (highlightInput) {
        highlightInput.value =
          editor.getAttributes("highlight").color || "#ffff00";
      }
    };

    this.editor = new Editor({
      element: this.el,
      editable: !isReadOnly,
      extensions: extensions,
      content: content,
      editorProps: {
        attributes: {
          class: "prose dark:prose-invert max-w-none focus:outline-none w-full",
        },
      },
      onUpdate: ({ editor }) => {
        if (isReadOnly) return;
        updateToolbarState(editor);
        clearTimeout(timeout);
        timeout = setTimeout(() => {
          hook.pushEvent("update_content", {
            id: blockId,
            content: editor.getJSON(),
          });
        }, 500);
      },
      onSelectionUpdate: ({ editor }) => {
        if (!isReadOnly) updateToolbarState(editor);
      },
      onTransaction: ({ editor }) => {
        if (!isReadOnly) updateToolbarState(editor);
      },
    });

    if (!isReadOnly) {
      const wrapper = this.el.closest(".editor-wrapper");
      const toolbar = wrapper ? wrapper.querySelector(".fixed-toolbar") : null;

      if (toolbar) {
        toolbar.addEventListener("click", (e) => {
          const btn = e.target.closest("button");
          if (!btn) return;
          e.preventDefault();
          const action = btn.dataset.action;

          const chain = this.editor.chain().focus();

          if (action === "bold") chain.toggleBold().run();
          if (action === "italic") chain.toggleItalic().run();
          if (action === "underline") chain.toggleUnderline().run();
          if (action === "unset-highlight") chain.unsetHighlight().run();
          if (action === "inline-code") chain.toggleCode().run();
          if (action === "subscript") chain.toggleSubscript().run();
          if (action === "superscript") chain.toggleSuperscript().run();

          if (action === "paragraph") chain.setParagraph().run();
          if (action === "h1") chain.toggleHeading({ level: 1 }).run();
          if (action === "h2") chain.toggleHeading({ level: 2 }).run();
          if (action === "h3") chain.toggleHeading({ level: 3 }).run();

          if (action === "bullet") chain.toggleBulletList().run();
          if (action === "ordered") chain.toggleOrderedList().run();

          if (action === "quote") chain.toggleBlockquote().run();
          if (action === "code-block") chain.toggleCodeBlock().run();
          if (action === "details") {
            if (this.editor.isActive("details")) {
              chain.unsetDetails().run();
            } else {
              chain.setDetails().run();
            }
          }
          if (action === "divider") chain.setHorizontalRule().run();

          if (action === "align-left") chain.setTextAlign("left").run();
          if (action === "align-center") chain.setTextAlign("center").run();
          if (action === "align-right") chain.setTextAlign("right").run();

          if (action === "table")
            chain.insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run();
          if (action === "add-row") chain.addRowAfter().run();
          if (action === "add-col") chain.addColumnAfter().run();
          if (action === "del-row") chain.deleteRow().run();
          if (action === "del-col") chain.deleteColumn().run();
          if (action === "del-table") chain.deleteTable().run();

          if (action === "link") {
            const url = window.prompt("URL:");
            if (url) chain.setLink({ href: url }).run();
          }
          if (action === "image") {
            hook.pushEvent("request_media_upload", {
              block_id: blockId,
              media_type: "tiptap_image",
            });
          }
        });

        toolbar.addEventListener("input", (e) => {
          if (
            e.target.tagName.toLowerCase() === "input" &&
            e.target.type === "color"
          ) {
            const action = e.target.dataset.action;
            const chain = this.editor.chain().focus();

            if (action === "text-color") chain.setColor(e.target.value).run();
            if (action === "highlight-color")
              chain.setHighlight({ color: e.target.value }).run();
          }
        });

        toolbar.addEventListener("change", (e) => {
          if (e.target.tagName.toLowerCase() === "select") {
            const action = e.target.dataset.action;
            const value = e.target.value;
            const chain = this.editor.chain().focus();

            if (action === "font-family") {
              if (value) chain.setFontFamily(value).run();
              else chain.unsetFontFamily().run();
            }
          }
        });

        toolbar.addEventListener("mousedown", (e) => {
          const tag = e.target.tagName.toLowerCase();
          if (tag !== "input" && tag !== "select" && tag !== "option") {
            e.preventDefault();
          }
        });
      }

      this.handleInsertMedia = (e) => {
        if (e.detail.block_id === blockId && e.detail.type === "tiptap_image") {
          this.editor.chain().focus().setImage({ src: e.detail.url }).run();
          hook.pushEvent("update_content", {
            id: blockId,
            content: this.editor.getJSON(),
          });
        }
      };
      window.addEventListener("phx:insert_media", this.handleInsertMedia);
    }
  },

  destroyed() {
    if (this.editor) this.editor.destroy();
    if (this.handleInsertMedia) {
      window.removeEventListener("phx:insert_media", this.handleInsertMedia);
    }
  },
};

let Uploaders = {};

Uploaders.S3 = function (entries, onViewError) {
  entries.forEach((entry) => {
    let { url } = entry.meta;
    let xhr = new XMLHttpRequest();

    onViewError(() => xhr.abort());

    xhr.open("PUT", url, true);

    xhr.onload = () => {
      if (xhr.status === 200) {
        entry.progress(100);
      } else {
        entry.error();
      }
    };

    xhr.onerror = () => {
      entry.error();
    };

    xhr.upload.addEventListener("progress", (event) => {
      if (event.lengthComputable) {
        let percent = Math.round((event.loaded / event.total) * 100);
        if (percent < 100) {
          entry.progress(percent);
        }
      }
    });

    xhr.send(entry.file);
  });
};

const liveSocket = new LiveSocket("/live", Socket, {
  uploaders: Uploaders,
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { ...colocatedHooks, ...Hooks },
});

const savedTheme = localStorage.getItem("phx:theme") || "system";
const html = document.documentElement;

const applyTheme = (theme) => {
  let activeTheme = theme;
  if (theme === "system") {
    activeTheme = window.matchMedia("(prefers-color-scheme: dark)").matches
      ? "dark"
      : "light";
  }
  html.setAttribute("data-theme", activeTheme);

  document.querySelectorAll(".theme-controller").forEach((cb) => {
    cb.checked = activeTheme === "dark";
  });
};

applyTheme(savedTheme);

window
  .matchMedia("(prefers-color-scheme: dark)")
  .addEventListener("change", (e) => {
    if (
      localStorage.getItem("phx:theme") === "system" ||
      !localStorage.getItem("phx:theme")
    ) {
      applyTheme("system");
    }
  });

window.addEventListener("phx:set-theme", (e) => {
  const newTheme = e.detail.theme;
  if (newTheme === "system") {
    localStorage.removeItem("phx:theme");
  } else {
    localStorage.setItem("phx:theme", newTheme);
  }
  applyTheme(newTheme);
});

topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());
window.addEventListener("phx:force_logout", (e) => {
  let csrfToken = document
    .querySelector("meta[name='csrf-token']")
    .getAttribute("content");
  fetch("/auth/log_out", {
    method: "DELETE",
    headers: {
      "X-CSRF-Token": csrfToken,
      "Content-Type": "application/json",
    },
  }).then(() => {
    window.location.href = "/auth/login";
  });
});
liveSocket.connect();
window.liveSocket = liveSocket;
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      reloader.enableServerLogs();
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (_e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true,
      );

      window.liveReloader = reloader;
    },
  );
}
