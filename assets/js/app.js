import { Editor, Extension } from "@tiptap/core";
import BubbleMenu from "@tiptap/extension-bubble-menu";
import CodeBlockLowlight from "@tiptap/extension-code-block-lowlight";
import Highlight from "@tiptap/extension-highlight";
import TiptapImage from "@tiptap/extension-image";
import Link from "@tiptap/extension-link";
import Table from "@tiptap/extension-table";
import TableCell from "@tiptap/extension-table-cell";
import TableHeader from "@tiptap/extension-table-header";
import TableRow from "@tiptap/extension-table-row";
import TextAlign from "@tiptap/extension-text-align";
import Underline from "@tiptap/extension-underline";
import StarterKit from "@tiptap/starter-kit";
import Suggestion from "@tiptap/suggestion";
import { common, createLowlight } from "lowlight";
import { Socket } from "phoenix";
import { hooks as colocatedHooks } from "phoenix-colocated/athena";
import "phoenix_html";
import { LiveSocket } from "phoenix_live_view";
import Sortable from "sortablejs";
import tippy from "tippy.js";
import "tippy.js/dist/tippy.css";
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

const getSuggestionItems = ({ query }) => {
  const items = [
    {
      title: "Paragraph",
      icon: "¶",
      command: ({ editor, range }) =>
        editor.chain().focus().deleteRange(range).setParagraph().run(),
    },
    {
      title: "Heading 1",
      icon: "H1",
      command: ({ editor, range }) =>
        editor
          .chain()
          .focus()
          .deleteRange(range)
          .toggleHeading({ level: 1 })
          .run(),
    },
    {
      title: "Heading 2",
      icon: "H2",
      command: ({ editor, range }) =>
        editor
          .chain()
          .focus()
          .deleteRange(range)
          .toggleHeading({ level: 2 })
          .run(),
    },
    {
      title: "Heading 3",
      icon: "H3",
      command: ({ editor, range }) =>
        editor
          .chain()
          .focus()
          .deleteRange(range)
          .toggleHeading({ level: 3 })
          .run(),
    },
    {
      title: "Bullet List",
      icon: "•",
      command: ({ editor, range }) =>
        editor.chain().focus().deleteRange(range).toggleBulletList().run(),
    },
    {
      title: "Quote",
      icon: "”",
      command: ({ editor, range }) =>
        editor.chain().focus().deleteRange(range).toggleBlockquote().run(),
    },
    {
      title: "Code Block",
      icon: "{}",
      command: ({ editor, range }) =>
        editor.chain().focus().deleteRange(range).toggleCodeBlock().run(),
    },
    {
      title: "Divider",
      icon: "—",
      command: ({ editor, range }) =>
        editor.chain().focus().deleteRange(range).setHorizontalRule().run(),
    },
    { title: "Image", icon: "🖼", type: "media", mediaType: "tiptap_image" },
    {
      title: "Table",
      icon: "▦",
      command: ({ editor, range }) =>
        editor
          .chain()
          .focus()
          .deleteRange(range)
          .insertTable({ rows: 3, cols: 3, withHeaderRow: true })
          .run(),
    },
  ];
  return items
    .filter((item) => item.title.toLowerCase().startsWith(query.toLowerCase()))
    .slice(0, 10);
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
          class: "rounded-lg max-h-[500px] shadow-sm my-4 mx-auto",
        },
      }),
      Highlight.configure({ multicolor: false }),
      TextAlign.configure({ types: ["heading", "paragraph"] }),
      Table.configure({ resizable: !isReadOnly }),
      TableRow,
      TableHeader,
      TableCell,
    ];

    if (!isReadOnly) {
      this.bubbleMenuEl = document.createElement("div");
      this.bubbleMenuEl.innerHTML = `
        <div class="join bg-base-100 shadow-xl border border-base-300 rounded-md">
          <button class="join-item btn btn-sm btn-ghost" data-action="bold" title="Bold"><b>B</b></button>
          <button class="join-item btn btn-sm btn-ghost" data-action="italic" title="Italic"><i>I</i></button>
          <button class="join-item btn btn-sm btn-ghost" data-action="underline" title="Underline"><u>U</u></button>
          <button class="join-item btn btn-sm btn-ghost" data-action="highlight" title="Highlight">🖍️</button>
          <button class="join-item btn btn-sm btn-ghost" data-action="code" title="Code">&lt;&gt;</button>
          <button class="join-item btn btn-sm btn-ghost" data-action="link" title="Link">🔗</button>
          <div class="divider divider-horizontal m-0 w-0 p-0"></div>
          <button class="join-item btn btn-sm btn-ghost" data-action="align-left" title="Align Left">⬅️</button>
          <button class="join-item btn btn-sm btn-ghost" data-action="align-center" title="Align Center">↔️</button>
          <button class="join-item btn btn-sm btn-ghost" data-action="align-right" title="Align Right">➡️</button>
        </div>
      `;
      extensions.push(BubbleMenu.configure({ element: this.bubbleMenuEl }));

      const SlashMenuPlugin = Extension.create({
        name: "slashMenu",
        addOptions() {
          return {
            suggestion: {
              char: "/",
              items: getSuggestionItems,
              render: () => {
                let popup;
                let selectedIndex = 0;
                let currentItems = [];
                let wrapper = document.createElement("div");
                wrapper.className =
                  "bg-base-100 shadow-2xl border border-base-300 rounded-lg p-1 w-56 flex flex-col gap-0.5 max-h-80 overflow-y-auto";

                const updateSelection = () => {
                  const buttons = wrapper.querySelectorAll("button");
                  buttons.forEach((btn, index) => {
                    if (index === selectedIndex) {
                      btn.classList.add("bg-base-200");
                      btn.scrollIntoView({ block: "nearest" });
                    } else {
                      btn.classList.remove("bg-base-200");
                    }
                  });
                };

                const executeItem = (item, range) => {
                  if (item.type === "media") {
                    hook.editor.chain().focus().deleteRange(range).run();
                    hook.pushEvent("request_media_upload", {
                      block_id: blockId,
                      media_type: item.mediaType,
                    });
                  } else {
                    item.command({ editor: hook.editor, range });
                  }
                  if (popup) popup[0].hide();
                };

                const renderHTML = (items) => {
                  currentItems = items;
                  wrapper.innerHTML = items
                    .map(
                      (item, index) => `
                    <button class="w-full text-left px-3 py-2 text-sm rounded-md flex items-center gap-2 transition-colors" data-index="${index}">
                      <span class="w-5 text-center text-base-content/50 font-bold">${item.icon}</span>
                      ${item.title}
                    </button>
                  `,
                    )
                    .join("");

                  wrapper.querySelectorAll("button").forEach((btn) => {
                    btn.addEventListener("click", (e) => {
                      e.preventDefault();
                      executeItem(
                        currentItems[btn.dataset.index],
                        popup[0].range,
                      );
                    });
                  });
                  updateSelection();
                };

                return {
                  onStart: (props) => {
                    selectedIndex = 0;
                    renderHTML(props.items);
                    popup = tippy("body", {
                      getReferenceClientRect: props.clientRect,
                      appendTo: () => document.body,
                      content: wrapper,
                      showOnCreate: true,
                      interactive: true,
                      trigger: "manual",
                      placement: "bottom-start",
                    });
                    popup[0].range = props.range;
                  },
                  onUpdate: (props) => {
                    selectedIndex = 0;
                    renderHTML(props.items);
                    popup[0].range = props.range;
                    popup[0].setProps({
                      getReferenceClientRect: props.clientRect,
                    });
                  },
                  onKeyDown: (props) => {
                    if (props.event.key === "ArrowUp") {
                      props.event.preventDefault();
                      selectedIndex =
                        (selectedIndex + currentItems.length - 1) %
                        currentItems.length;
                      updateSelection();
                      return true;
                    }
                    if (props.event.key === "ArrowDown") {
                      props.event.preventDefault();
                      selectedIndex = (selectedIndex + 1) % currentItems.length;
                      updateSelection();
                      return true;
                    }
                    if (props.event.key === "Enter") {
                      props.event.preventDefault();
                      if (currentItems.length > 0) {
                        executeItem(currentItems[selectedIndex], props.range);
                      }
                      return true;
                    }
                    if (props.event.key === "Escape") {
                      props.event.preventDefault();
                      popup[0].hide();
                      return true;
                    }
                    return false;
                  },
                  onExit: () => {
                    if (popup) popup[0].destroy();
                  },
                };
              },
            },
          };
        },
        addProseMirrorPlugins() {
          return [
            Suggestion({ editor: this.editor, ...this.options.suggestion }),
          ];
        },
      });
      extensions.push(SlashMenuPlugin);
    }

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

        clearTimeout(timeout);
        timeout = setTimeout(() => {
          hook.pushEvent("update_content", {
            id: blockId,
            content: editor.getJSON(),
          });
        }, 500);
      },
    });

    if (!isReadOnly) {
      this.bubbleMenuEl.addEventListener("click", (e) => {
        e.preventDefault();
        const action = e.target.closest("button")?.dataset.action;
        if (!action) return;

        if (action === "bold") this.editor.chain().focus().toggleBold().run();
        if (action === "italic")
          this.editor.chain().focus().toggleItalic().run();
        if (action === "underline")
          this.editor.chain().focus().toggleUnderline().run();
        if (action === "highlight")
          this.editor.chain().focus().toggleHighlight().run();
        if (action === "code") this.editor.chain().focus().toggleCode().run();
        if (action === "link") {
          const url = window.prompt("URL:");
          if (url) this.editor.chain().focus().setLink({ href: url }).run();
        }
        if (action === "align-left")
          this.editor.chain().focus().setTextAlign("left").run();
        if (action === "align-center")
          this.editor.chain().focus().setTextAlign("center").run();
        if (action === "align-right")
          this.editor.chain().focus().setTextAlign("right").run();
      });

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
