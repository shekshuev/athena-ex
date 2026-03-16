// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { hooks as colocatedHooks } from "phoenix-colocated/athena";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";
import Sortable from "sortablejs";
import { Editor, Extension, Node, mergeAttributes } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import TiptapImage from "@tiptap/extension-image";
import BubbleMenu from "@tiptap/extension-bubble-menu";
import Underline from "@tiptap/extension-underline";
import Link from "@tiptap/extension-link";
import Suggestion from "@tiptap/suggestion";
import tippy from "tippy.js";
import "tippy.js/dist/tippy.css";

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

const VideoNode = Node.create({
  name: "video",
  group: "block",
  atom: true,
  draggable: true,
  addAttributes() {
    return {
      src: { default: null },
      type: { default: "video/mp4" },
    };
  },
  parseHTML() {
    return [{ tag: "video[src]" }];
  },
  renderHTML({ HTMLAttributes }) {
    return [
      "video",
      mergeAttributes(HTMLAttributes, {
        controls: "true",
        class: "w-full rounded-lg shadow-sm bg-black my-4",
      }),
    ];
  },
});

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
    { title: "Image", icon: "🖼", type: "media", mediaType: "image" },
    { title: "Video", icon: "🎥", type: "media", mediaType: "video" },
  ];
  return items
    .filter((item) => item.title.toLowerCase().startsWith(query.toLowerCase()))
    .slice(0, 10);
};

Hooks.TiptapEditor = {
  mounted() {
    const hook = this;
    const content = this.el.dataset.content
      ? JSON.parse(this.el.dataset.content)
      : "";
    const blockId = this.el.dataset.id;

    this.bubbleMenuEl = document.createElement("div");
    this.bubbleMenuEl.innerHTML = `
      <div class="join bg-base-100 shadow-xl border border-base-300 rounded-md">
        <button class="join-item btn btn-sm btn-ghost" data-action="bold"><b>B</b></button>
        <button class="join-item btn btn-sm btn-ghost" data-action="italic"><i>I</i></button>
        <button class="join-item btn btn-sm btn-ghost" data-action="underline"><u>U</u></button>
        <button class="join-item btn btn-sm btn-ghost" data-action="code">&lt;&gt;</button>
        <button class="join-item btn btn-sm btn-ghost" data-action="link">🔗</button>
      </div>
    `;

    let timeout;

    const SlashMenuPlugin = Extension.create({
      name: "slashMenu",
      addOptions() {
        return {
          suggestion: {
            char: "/",
            command: ({ editor, range, props }) => {
              if (props.type === "media") {
                editor.chain().focus().deleteRange(range).run();
                hook.pushEvent("request_media_upload", {
                  block_id: blockId,
                  media_type: props.mediaType,
                });
              } else {
                props.command({ editor, range });
              }
            },
            items: getSuggestionItems,
            render: () => {
              let component, popup;
              return {
                onStart: (props) => {
                  const html = props.items
                    .map(
                      (item, index) => `
                    <button class="w-full text-left px-3 py-2 text-sm hover:bg-base-200 rounded-md flex items-center gap-2 ${index === 0 ? "bg-base-200" : ""}" data-index="${index}">
                      <span class="w-5 text-center text-base-content/50 font-bold">${item.icon}</span>
                      ${item.title}
                    </button>
                  `,
                    )
                    .join("");

                  const wrapper = document.createElement("div");
                  wrapper.className =
                    "bg-base-100 shadow-2xl border border-base-300 rounded-lg p-1 w-56 flex flex-col gap-0.5";
                  wrapper.innerHTML = html;

                  wrapper.addEventListener("click", (e) => {
                    const btn = e.target.closest("button");
                    if (btn) props.command(props.items[btn.dataset.index]);
                  });

                  popup = tippy("body", {
                    getReferenceClientRect: props.clientRect,
                    appendTo: () => document.body,
                    content: wrapper,
                    showOnCreate: true,
                    interactive: true,
                    trigger: "manual",
                    placement: "bottom-start",
                    theme: "light-border",
                  });
                },
                onUpdate: (props) => {
                  if (popup)
                    popup[0].setProps({
                      getReferenceClientRect: props.clientRect,
                    });
                },
                onKeyDown: (props) => {
                  if (props.event.key === "Escape") {
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

    this.editor = new Editor({
      element: this.el,
      extensions: [
        StarterKit,
        Underline,
        Link.configure({ openOnClick: false }),
        TiptapImage.configure({
          inline: false,
          HTMLAttributes: {
            class: "rounded-lg max-h-[500px] shadow-sm my-4 mx-auto",
          },
        }),
        VideoNode,
        BubbleMenu.configure({ element: this.bubbleMenuEl }),
        SlashMenuPlugin,
      ],
      content: content,
      editorProps: {
        attributes: {
          class:
            "prose dark:prose-invert max-w-none focus:outline-none min-h-[50px] w-full",
        },
      },
      onUpdate: ({ editor }) => {
        clearTimeout(timeout);
        timeout = setTimeout(() => {
          hook.pushEvent("update_content", {
            id: blockId,
            content: editor.getJSON(),
          });
        }, 500);
      },
    });

    this.bubbleMenuEl.addEventListener("click", (e) => {
      e.preventDefault();
      const action = e.target.closest("button")?.dataset.action;
      if (action === "bold") this.editor.chain().focus().toggleBold().run();
      if (action === "italic") this.editor.chain().focus().toggleItalic().run();
      if (action === "underline")
        this.editor.chain().focus().toggleUnderline().run();
      if (action === "code") this.editor.chain().focus().toggleCode().run();
      if (action === "link") {
        const url = window.prompt("URL:");
        if (url) this.editor.chain().focus().setLink({ href: url }).run();
      }
    });

    this.handleInsertMedia = (e) => {
      if (e.detail.block_id === blockId) {
        if (e.detail.type === "image") {
          this.editor.chain().focus().setImage({ src: e.detail.url }).run();
        } else if (e.detail.type === "video") {
          this.editor
            .chain()
            .focus()
            .insertContent({ type: "video", attrs: { src: e.detail.url } })
            .run();
        }
        hook.pushEvent("update_content", {
          id: blockId,
          content: this.editor.getJSON(),
        });
      }
    };
    window.addEventListener("phx:insert_media", this.handleInsertMedia);
  },

  destroyed() {
    if (this.editor) this.editor.destroy();
    window.removeEventListener("phx:insert_media", this.handleInsertMedia);
  },
};

const liveSocket = new LiveSocket("/live", Socket, {
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

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client.
      // Disable with reloader.disableServerLogs()
      reloader.enableServerLogs();

      // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
      //
      //   * click with "c" key pressed to open at caller location
      //   * click with "d" key pressed to open at function component definition location
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
