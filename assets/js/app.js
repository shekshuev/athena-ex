import { cpp } from "@codemirror/lang-cpp";
import { css } from "@codemirror/lang-css";
import { go } from "@codemirror/lang-go";
import { html } from "@codemirror/lang-html";
import { java } from "@codemirror/lang-java";
import { javascript } from "@codemirror/lang-javascript";
import { json } from "@codemirror/lang-json";
import { markdown } from "@codemirror/lang-markdown";
import { php } from "@codemirror/lang-php";
import { python } from "@codemirror/lang-python";
import { rust } from "@codemirror/lang-rust";
import { sql } from "@codemirror/lang-sql";
import { xml } from "@codemirror/lang-xml";
import { yaml } from "@codemirror/lang-yaml";
import { Compartment, EditorState } from "@codemirror/state";
import { oneDark } from "@codemirror/theme-one-dark";
import { Editor, Extension } from "@tiptap/core";
import CodeBlockLowlight from "@tiptap/extension-code-block-lowlight";
import Color from "@tiptap/extension-color";
import Details from "@tiptap/extension-details";
import DetailsContent from "@tiptap/extension-details-content";
import DetailsSummary from "@tiptap/extension-details-summary";
import Highlight from "@tiptap/extension-highlight";
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
import { EditorView, basicSetup } from "codemirror";
import { common, createLowlight } from "lowlight";
import * as mammoth from "mammoth";
import { Socket } from "phoenix";
import { hooks as colocatedHooks } from "phoenix-colocated/athena";
import "phoenix_html";
import { LiveSocket } from "phoenix_live_view";
import Sortable from "sortablejs";
import tippy from "tippy.js";
import "tippy.js/dist/tippy.css";
import ImageResize from "tiptap-extension-resize-image";
import topbar from "../vendor/topbar";
import { Dialogue, DialogueLine, insertDialogue } from "./tiptap/dialogue";
import { ChartsHooks } from "./charts_hooks";
import { EngagementHooks, engagementTrackingActive } from "./engagement_hooks";
import { MessengerHooks } from "./messenger_hooks";

const lowlight = createLowlight(common);

const ResizableImage = ImageResize.extend({
  name: "image",
});

const safeUUID = () => {
  if (
    typeof window !== "undefined" &&
    window.crypto &&
    window.crypto.randomUUID
  ) {
    return window.crypto.randomUUID();
  }
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function (c) {
    const r = (Math.random() * 16) | 0;
    const v = c === "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
};

const isMac =
  typeof window !== "undefined" &&
  navigator.userAgent.toUpperCase().indexOf("MAC") >= 0;
const modKey = isMac ? "⌘" : "Ctrl";
const altKey = isMac ? "⌥" : "Alt";
const shiftKey = isMac ? "⇧" : "Shift";

tippy.setDefaultProps({
  theme: "athena",
  delay: [200, 0],
  animation: "fade",
  arrow: true,
  onShow(instance) {
    let content = instance.reference.getAttribute("data-tippy-content");
    if (content) {
      content = content
        .replace(/\$mod/g, modKey)
        .replace(/\$alt/g, altKey)
        .replace(/\$shift/g, shiftKey);
      instance.setContent(content);
    }
  },
});

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const Hooks = {};

Object.assign(Hooks, EngagementHooks);
Object.assign(Hooks, ChartsHooks);
Object.assign(Hooks, MessengerHooks);

Hooks.TippyTooltip = {
  mounted() {
    this.instance = tippy(this.el, {
      content: this.el.getAttribute("data-tippy-content"),
      theme: "athena",
      delay: [200, 0],
      animation: "fade",
    });
  },
  updated() {
    if (this.instance) {
      this.instance.setContent(this.el.getAttribute("data-tippy-content"));
    }
  },
  destroyed() {
    if (this.instance) {
      this.instance.destroy();
    }
  },
};

Hooks.CodeEditor = {
  mounted() {
    const isReadOnly = this.el.dataset.readonly === "true";
    const language = this.el.dataset.language;

    // Engagement: only the student-facing answer editor (`code-input-<block
    // id>`) matters for paste-ratio/TTFA - the Builder's setup/solution SQL
    // editors use a different input-id pattern and are intentionally not
    // matched here.
    const answerBlockId = (this.el.dataset.inputId || "").match(
      /^code-input-(.+)$/,
    )?.[1];
    let firstInteractionSent = false;

    let langExtension = python();
    switch (language) {
      case "python":
        langExtension = python();
        break;
      case "cpp":
        langExtension = cpp();
        break;
      case "sql":
        langExtension = sql();
        break;
      case "javascript":
        langExtension = javascript();
        break;
      case "html":
        langExtension = html();
        break;
      case "css":
        langExtension = css();
        break;
      case "json":
        langExtension = json();
        break;
      case "markdown":
        langExtension = markdown();
        break;
      case "yaml":
        langExtension = yaml();
        break;
      case "rust":
        langExtension = rust();
        break;
      case "go":
        langExtension = go();
        break;
      case "java":
        langExtension = java();
        break;
      case "php":
        langExtension = php();
        break;
      case "xml":
        langExtension = xml();
        break;
    }

    const themeCompartment = new Compartment();

    const isDark = () =>
      document.documentElement.getAttribute("data-theme") === "dark";

    let extensions = [
      basicSetup,
      langExtension,
      themeCompartment.of(isDark() ? oneDark : []),
      EditorView.theme({
        "&": { height: "300px", fontSize: "14px" },
        ".cm-scroller": { overflow: "auto" },
      }),
      EditorView.updateListener.of((update) => {
        if (update.docChanged && !isReadOnly) {
          const code = update.state.doc.toString();
          const inputId = this.el.dataset.inputId;
          if (inputId) {
            const hiddenInput = document.getElementById(inputId);
            if (hiddenInput) {
              hiddenInput.value = code;
              hiddenInput.dispatchEvent(new Event("input", { bubbles: true }));
            }
          }

          if (!firstInteractionSent && answerBlockId && engagementTrackingActive()) {
            firstInteractionSent = true;
            this.pushEvent("engagement_batch", {
              events: [
                {
                  block_id: answerBlockId,
                  event_type: "first_interaction",
                  occurred_at: new Date().toISOString(),
                },
              ],
            });
          }
        }
      }),
    ];

    if (isReadOnly) {
      extensions.push(EditorState.readOnly.of(true));
    }

    this.editor = new EditorView({
      doc: this.el.dataset.code || "",
      extensions: extensions,
      parent: this.el,
    });

    this.applyCmTheme = () => {
      const dark = isDark();
      this.editor.dispatch({
        effects: themeCompartment.reconfigure(dark ? oneDark : []),
      });
    };

    window.addEventListener("phx:set-theme", this.applyCmTheme);

    this.observer = new MutationObserver((mutations) => {
      for (const m of mutations) {
        if (m.attributeName === "data-theme") this.applyCmTheme();
      }
    });
    this.observer.observe(document.documentElement, { attributes: true });

    if (!isReadOnly && answerBlockId) {
      this.handlePaste = (event) => {
        if (!engagementTrackingActive()) return;
        const text = event.clipboardData?.getData("text/plain") || "";
        if (!text) return;

        const totalChars = this.editor.state.doc.length + text.length;
        this.pushEvent("engagement_batch", {
          events: [
            {
              block_id: answerBlockId,
              event_type: "paste_detected",
              payload: { pasted_chars: text.length, total_chars: totalChars },
              occurred_at: new Date().toISOString(),
            },
          ],
        });
      };
      this.editor.dom.addEventListener("paste", this.handlePaste);
    }
  },

  destroyed() {
    if (this.editor) this.editor.destroy();
    window.removeEventListener("phx:set-theme", this.applyCmTheme);
    if (this.observer) this.observer.disconnect();
    if (this.handlePaste && this.editor) {
      this.editor.dom.removeEventListener("paste", this.handlePaste);
    }
  },
};

Hooks.Sortable = {
  mounted() {
    const eventName = this.el.dataset.eventName || "reorder";

    this.sortable = new Sortable(this.el, {
      animation: 150,
      handle: ".drag-handle",
      ghostClass: "bg-base-200",
      onEnd: (evt) => {
        this.pushEvent(eventName, {
          ...this.el.dataset,
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

Hooks.TiptapEditor = {
  mounted() {
    const hook = this;
    const content = this.el.dataset.content
      ? JSON.parse(this.el.dataset.content)
      : "";
    const blockId = this.el.dataset.id;
    const isReadOnly = this.el.dataset.readonly === "true";
    let timeout;

    hook.characters = this.el.dataset.characters
      ? JSON.parse(this.el.dataset.characters)
      : [];

    this.handleCharactersUpdated = (e) => {
      hook.characters = e.detail.characters;
    };
    window.addEventListener("phx:characters_updated", this.handleCharactersUpdated);

    this.clipboardFiles = {};

    const uploadBlobToS3 = (blobEntry) => {
      Uploaders.S3([blobEntry], () => {});
    };

    const SmartSpacer = Extension.create({
      name: "smartSpacer",
      addKeyboardShortcuts() {
        return {
          "Alt-Enter": () => {
            const pos = this.editor.state.selection.$to.after(1);
            return this.editor
              .chain()
              .insertContentAt(pos, { type: "paragraph" })
              .focus(pos + 1)
              .run();
          },
          "Shift-Alt-Enter": () => {
            const pos = this.editor.state.selection.$from.before(1);
            return this.editor
              .chain()
              .insertContentAt(pos, { type: "paragraph" })
              .focus(pos + 1)
              .run();
          },
        };
      },
    });

    const getTiptapExtensions = (readOnlyMode) => [
      StarterKit.configure({ codeBlock: false }),
      SmartSpacer,
      CodeBlockLowlight.configure({ lowlight }),
      Underline,
      Link.configure({ openOnClick: readOnlyMode }),
      Highlight.configure({ multicolor: true }),
      TextAlign.configure({ types: ["heading", "paragraph"] }),
      Table.configure({ resizable: !readOnlyMode, renderWrapper: true }),
      TableRow,
      TableHeader,
      TableCell,
      Placeholder.configure({
        includeChildren: true,
        placeholder: ({ node }) => {
          if (node.type.name === "detailsSummary") return "Spoiler header...";
          return "Type here...";
        },
        emptyEditorClass: "is-editor-empty",
      }),
      TextStyle,
      Color,
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
      Details.configure({ HTMLAttributes: { class: "tiptap-details" } }),
      DetailsSummary.configure({
        HTMLAttributes: { class: "tiptap-details-summary" },
      }),
      DetailsContent.configure({
        HTMLAttributes: { class: "tiptap-details-content" },
      }),
      ResizableImage.configure({
        inline: false,
        HTMLAttributes: {
          class: readOnlyMode
            ? "rounded-sm my-4 mx-auto js-lightbox-img cursor-zoom-in"
            : "rounded-sm my-4 mx-auto",
        },
      }),
      Dialogue,
      DialogueLine.configure({
        getCharacters: () => hook.characters,
        onManageCharacters: () => hook.pushEvent("open_character_manager", {}),
      }),
    ];

    const extensions = getTiptapExtensions(isReadOnly);

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

      const langControl = toolbar.querySelector(".tiptap-lang-control");
      if (langControl) {
        if (editor.isActive("codeBlock")) {
          langControl.classList.remove("hidden");

          const currentLang =
            editor.getAttributes("codeBlock").language || "auto";

          const label = langControl.querySelector(".current-lang-label");
          if (label) {
            const langItem = langControl.querySelector(
              `[data-lang="${currentLang}"]`,
            );
            label.textContent = langItem
              ? langItem.textContent
              : currentLang.toUpperCase();
          }
        } else {
          langControl.classList.add("hidden");
        }
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
        handleKeyDown: (view, event) => {
          if (isReadOnly) return false;

          const isMod = event.ctrlKey || event.metaKey;

          if (isMod && event.key === ",") {
            event.preventDefault();
            this.editor.chain().focus().toggleSubscript().run();
            return true;
          }

          if (isMod && event.key === ".") {
            event.preventDefault();
            this.editor.chain().focus().toggleSuperscript().run();
            return true;
          }

          if (isMod && event.key.toLowerCase() === "k") {
            event.preventDefault();
            const url = window.prompt("URL:");
            if (url) this.editor.chain().focus().setLink({ href: url }).run();
            return true;
          }

          if (isMod && event.altKey && event.key.toLowerCase() === "t") {
            event.preventDefault();
            this.editor
              .chain()
              .focus()
              .insertTable({ rows: 3, cols: 3, withHeaderRow: true })
              .run();
            return true;
          }

          if (isMod && event.shiftKey && event.key.toLowerCase() === "d") {
            event.preventDefault();
            if (this.editor.isActive("details")) {
              this.editor.chain().focus().unsetDetails().run();
            } else {
              this.editor.chain().focus().setDetails().run();
            }
            return true;
          }

          if (isMod && event.shiftKey && event.key.toLowerCase() === "i") {
            event.preventDefault();
            hook.pushEvent("request_media_upload", {
              block_id: blockId,
              media_type: "tiptap_image",
            });
            return true;
          }

          if (isMod && event.key === "Enter") {
            event.preventDefault();
            this.editor.chain().focus().setHorizontalRule().run();
            return true;
          }

          if (isMod && event.shiftKey && event.key.toLowerCase() === "l") {
            event.preventDefault();
            this.editor.chain().focus().setTextAlign("left").run();
            return true;
          }
          if (isMod && event.shiftKey && event.key.toLowerCase() === "e") {
            event.preventDefault();
            this.editor.chain().focus().setTextAlign("center").run();
            return true;
          }
          if (isMod && event.shiftKey && event.key.toLowerCase() === "r") {
            event.preventDefault();
            this.editor.chain().focus().setTextAlign("right").run();
            return true;
          }

          if (isMod && event.shiftKey && event.key.toLowerCase() === "j") {
            event.preventDefault();
            this.editor.chain().focus().setTextAlign("justify").run();
            return true;
          }

          if (isMod && event.key === "\\") {
            event.preventDefault();
            this.editor.chain().focus().unsetAllMarks().clearNodes().run();
            return true;
          }

          return false;
        },
        handlePaste: (view, event, slice) => {
          if (isReadOnly) return false;

          const clipboardData = event.clipboardData || window.clipboardData;
          if (!clipboardData) return false;

          const types = clipboardData.types || [];
          const hasHtml = types.includes("text/html");

          const items = Array.from(clipboardData.items);
          const imageItems = items.filter(
            (item) => item.kind === "file" && item.type.startsWith("image/"),
          );

          if (hasHtml && imageItems.length > 0) {
            const htmlData = clipboardData.getData("text/html");

            if (htmlData.includes("file://")) {
              event.preventDefault();

              const text = clipboardData.getData("text/plain");
              if (text) {
                this.editor.chain().focus().insertContent(text).run();
              }

              imageItems.forEach((item) => {
                const file = item.getAsFile();
                const tempId = safeUUID();

                hook.clipboardFiles[tempId] = file;

                hook.pushEvent("media_upload_clipboard_request", {
                  block_id: blockId,
                  file_name: `clipboard_${tempId.substring(0, 8)}.png`,
                  file_type: file.type,
                  file_size: file.size,
                  temp_id: tempId,
                });
              });

              return true;
            }
          }

          if (imageItems.length > 0) {
            event.preventDefault();

            imageItems.forEach((item) => {
              const file = item.getAsFile();
              const tempId = safeUUID();

              hook.clipboardFiles[tempId] = file;

              hook.pushEvent("media_upload_clipboard_request", {
                block_id: blockId,
                file_name: `clipboard_${tempId.substring(0, 8)}.png`,
                file_type: file.type,
                file_size: file.size,
                temp_id: tempId,
              });
            });
            return true;
          }

          // Engagement: only the student open-answer field
          // (`open-answer-<block id>`) matters for the "did they paste it or
          // write it" metric - the general text-block authoring editor uses
          // this same hook with no input-id and is intentionally skipped.
          const openAnswerInputId = hook.el.dataset.inputId || "";
          if (
            !isReadOnly &&
            openAnswerInputId.startsWith("open-answer-") &&
            engagementTrackingActive()
          ) {
            const text = clipboardData.getData("text/plain") || "";
            if (text) {
              const totalChars = hook.editor.getText().length + text.length;
              hook.pushEvent("engagement_batch", {
                events: [
                  {
                    block_id: blockId,
                    event_type: "paste_detected",
                    payload: { pasted_chars: text.length, total_chars: totalChars },
                    occurred_at: new Date().toISOString(),
                  },
                ],
              });
            }
          }

          return false;
        },
      },
      onUpdate: ({ editor }) => {
        if (isReadOnly) return;
        updateToolbarState(editor);
        clearTimeout(timeout);
        timeout = setTimeout(() => {
          const inputId = hook.el.dataset.inputId;

          if (inputId) {
            const hiddenInput = document.getElementById(inputId);
            if (hiddenInput) {
              hiddenInput.value = JSON.stringify(editor.getJSON());
              hiddenInput.dispatchEvent(new Event("input", { bubbles: true }));
            }
          } else {
            const onChangeEvent = hook.el.dataset.onChange;

            if (onChangeEvent) {
              const payload = { id: blockId, content: editor.getJSON() };
              const target = hook.el.getAttribute("phx-target");

              if (target) {
                hook.pushEventTo(target, onChangeEvent, payload);
              } else {
                hook.pushEvent(onChangeEvent, payload);
              }
            }
          }
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
        tippy(toolbar.querySelectorAll("[data-tippy-content]"));

        toolbar.addEventListener("click", (e) => {
          const toggleBtn = e.target.closest(
            '[data-action="toggle-lang-dropdown"]',
          );
          if (toggleBtn) {
            e.preventDefault();
            e.stopPropagation();
            const dropdown = toggleBtn.closest(".dropdown");
            dropdown.classList.toggle("dropdown-open");
            return;
          }

          const langItem = e.target.closest("[data-lang]");
          if (langItem) {
            e.preventDefault();
            e.stopPropagation();
            const value = langItem.dataset.lang;

            this.editor
              .chain()
              .focus()
              .updateAttributes("codeBlock", {
                language: value === "auto" ? null : value,
              })
              .run();

            const dropdown = langItem.closest(".dropdown");
            if (dropdown) dropdown.classList.remove("dropdown-open");
            return;
          }

          const dropdown = toolbar.querySelector(".tiptap-lang-control");
          if (dropdown) dropdown.classList.remove("dropdown-open");

          const btn = e.target.closest("button");
          if (!btn) return;
          e.preventDefault();
          const action = btn.dataset.action;

          const chain = this.editor.chain().focus();

          if (action === "bold") chain.toggleBold().run();
          if (action === "italic") chain.toggleItalic().run();
          if (action === "underline") chain.toggleUnderline().run();
          if (action === "highlight") chain.toggleHighlight().run();
          if (action === "clear-format") {
            chain.unsetAllMarks().clearNodes().run();
          }

          if (action === "insert-before") {
            try {
              const pos = this.editor.state.selection.$from.before(1);
              this.editor
                .chain()
                .insertContentAt(pos, { type: "paragraph" })
                .focus(pos + 1)
                .run();
            } catch (e) {
              console.warn("Cannot insert before root");
            }
          }

          if (action === "insert-after") {
            try {
              const pos = this.editor.state.selection.$to.after(1);
              this.editor
                .chain()
                .insertContentAt(pos, { type: "paragraph" })
                .focus(pos + 1)
                .run();
            } catch (e) {
              console.warn("Cannot insert after root");
            }
          }
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
          if (action === "code-block") {
            if (this.editor.isActive("codeBlock")) {
              chain.toggleCodeBlock().run();
            } else {
              const { from, to, empty } = this.editor.state.selection;
              if (!empty) {
                const text = this.editor.state.doc.textBetween(from, to, "\n");
                chain
                  .deleteRange({ from, to })
                  .insertContent({
                    type: "codeBlock",
                    content: [{ type: "text", text }],
                  })
                  .run();
              } else {
                chain.toggleCodeBlock().run();
              }
            }
          }
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
          if (action === "align-justify") chain.setTextAlign("justify").run();

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
          if (action === "dialogue") insertDialogue(this.editor);
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
          if (e.target.classList.contains("tiptap-word-import")) {
            const file = e.target.files[0];
            if (!file) return;

            this.editor.setEditable(false);

            const reader = new FileReader();
            reader.onload = (loadEvent) => {
              mammoth
                .convertToHtml({ arrayBuffer: loadEvent.target.result })
                .then((result) => {
                  this.editor.setEditable(true);
                  this.editor.chain().focus().insertContent(result.value).run();
                  e.target.value = "";

                  this.editor.state.doc.descendants((node, pos) => {
                    if (
                      node.type.name === "image" &&
                      node.attrs.src.startsWith("data:image")
                    ) {
                      const tempId = safeUUID();

                      this.editor
                        .chain()
                        .setNodeSelection(pos)
                        .command(({ tr }) => {
                          tr.setNodeMarkup(pos, null, {
                            ...node.attrs,
                            alt: tempId,
                          });
                          return true;
                        })
                        .run();

                      fetch(node.attrs.src)
                        .then((res) => res.blob())
                        .then((blob) => {
                          hook.clipboardFiles[tempId] = blob;
                          hook.pushEvent("media_upload_clipboard_request", {
                            block_id: blockId,
                            file_name: `word_import_${tempId.substring(0, 8)}.png`,
                            file_type: blob.type,
                            file_size: blob.size,
                            temp_id: tempId,
                          });
                        });
                    }
                  });

                  hook.pushEvent("update_content", {
                    id: blockId,
                    content: this.editor.getJSON(),
                  });
                })
                .catch((err) => {
                  console.error("Word import error:", err);
                  this.editor.setEditable(true);
                  e.target.value = "";
                });
            };
            reader.readAsArrayBuffer(file);
            return;
          }

        });

        toolbar.addEventListener("mousedown", (e) => {
          const tag = e.target.tagName.toLowerCase();
          if (tag !== "input" && tag !== "select" && tag !== "option") {
            e.preventDefault();
          }
        });
      }

      this.handleClipboardPresigned = (e) => {
        const { temp_id, upload_url, final_url } = e.detail;

        const blob = this.clipboardFiles[temp_id];
        if (!blob) return;

        const blobEntry = {
          file: blob,
          tempId: temp_id,
          meta: { url: upload_url },

          progress: (percent) => {
            if (percent === 100) {
              hook.pushEvent("media_upload_clipboard_success", {
                block_id: blockId,
                temp_id: temp_id,
                final_url: final_url,
              });

              delete this.clipboardFiles[temp_id];
            }
          },

          error: () => {
            delete this.clipboardFiles[temp_id];
          },
        };

        uploadBlobToS3(blobEntry);
      };
      window.addEventListener(
        "phx:media_upload_presigned",
        this.handleClipboardPresigned,
      );

      this.handleInsertMedia = (e) => {
        if (e.detail.block_id === blockId && e.detail.type === "tiptap_image") {
          let replaced = false;
          const tempId = e.detail.temp_id;

          if (tempId) {
            this.editor.state.doc.descendants((node, pos) => {
              if (node.type.name === "image" && node.attrs.alt === tempId) {
                this.editor
                  .chain()
                  .setNodeSelection(pos)
                  .command(({ tr }) => {
                    tr.setNodeMarkup(pos, null, {
                      ...node.attrs,
                      src: e.detail.url,
                      alt: "",
                    });
                    return true;
                  })
                  .run();
                replaced = true;
              }
            });
          }

          if (!replaced) {
            this.editor.chain().focus().setImage({ src: e.detail.url }).run();
          }

          hook.pushEvent("update_content", {
            id: blockId,
            content: this.editor.getJSON(),
          });
        }
      };
      window.addEventListener("phx:insert_media", this.handleInsertMedia);
    }

    this.handleGlobalClick = (e) => {
      const wrapper = hook.el.closest(".editor-wrapper");
      if (wrapper && !wrapper.contains(e.target)) {
        const dropdown = wrapper.querySelector(".tiptap-lang-control");
        if (dropdown) dropdown.classList.remove("dropdown-open");
      }
    };
    document.addEventListener("click", this.handleGlobalClick);

    // Reserved `image_zoom` telemetry (see `Athena.Engagement.Event`) for
    // the lightbox opened by app.js's document-level click listener on
    // `.js-lightbox-img` - only these read-only-rendered images carry that
    // class (see the `ResizableImage` config above), so this never fires in
    // the editable Builder/Library views.
    this.handleImageZoom = (e) => {
      const img = e.target.closest(".js-lightbox-img");
      if (!img || !isReadOnly || !engagementTrackingActive()) return;

      hook.pushEvent("engagement_batch", {
        events: [
          {
            block_id: blockId,
            event_type: "image_zoom",
            payload: {},
            occurred_at: new Date().toISOString(),
          },
        ],
      });
    };
    this.el.addEventListener("click", this.handleImageZoom);
  },

  destroyed() {
    if (this.editor) this.editor.destroy();
    if (this.handleInsertMedia) {
      window.removeEventListener("phx:insert_media", this.handleInsertMedia);
    }
    if (this.handleCharactersUpdated) {
      window.removeEventListener(
        "phx:characters_updated",
        this.handleCharactersUpdated,
      );
    }

    document.removeEventListener("click", this.handleGlobalClick);
    this.el.removeEventListener("click", this.handleImageZoom);
  },
};

Hooks.FlashAutohide = {
  mounted() {
    this.startTimeout();
  },
  updated() {
    clearTimeout(this.timeout);
    this.startTimeout();
  },
  destroyed() {
    clearTimeout(this.timeout);
  },
  startTimeout() {
    this.timeout = setTimeout(() => {
      if (this.el) {
        this.el.click();
      }
    }, 5000);
  },
};

Hooks.Sidebar = {
  mounted() {
    const isCollapsed = localStorage.getItem("sidebar-collapsed") === "true";

    if (isCollapsed) {
      this.el.classList.add("is-collapsed");
    }
    this.observer = new MutationObserver((mutations) => {
      mutations.forEach((m) => {
        if (m.attributeName === "class") {
          const hasClass = this.el.classList.contains("is-collapsed");
          localStorage.setItem("sidebar-collapsed", hasClass);
        }
      });
    });

    this.observer.observe(this.el, {
      attributes: true,
      attributeFilter: ["class"],
    });

    // Navigating between top-level LiveViews (Dashboard -> Files ->
    // Announcements, etc.) fully remounts this layout — `mounted()` fires
    // again on every such navigation (not on same-page `push_patch`es like
    // search/pagination) — so both of the below only need to run once here.
    this.highlightActiveLink();

    const nav = this.el.querySelector("nav");
    if (nav) {
      const savedScroll = sessionStorage.getItem("sidebar-nav-scroll");
      if (savedScroll) nav.scrollTop = parseInt(savedScroll, 10);

      this.saveScroll = () => {
        sessionStorage.setItem("sidebar-nav-scroll", nav.scrollTop);
      };
      nav.addEventListener("scroll", this.saveScroll);
    }
  },
  highlightActiveLink() {
    const links = this.el.querySelectorAll("nav a[href]");
    const currentPath = window.location.pathname;
    let bestMatch = null;
    let bestLength = -1;

    links.forEach((link) => {
      link.classList.remove("menu-active");
      const linkPath = new URL(link.href, window.location.origin).pathname;
      const matches =
        currentPath === linkPath || currentPath.startsWith(`${linkPath}/`);

      if (matches && linkPath.length > bestLength) {
        bestMatch = link;
        bestLength = linkPath.length;
      }
    });

    if (bestMatch) bestMatch.classList.add("menu-active");
  },
  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
    }

    const nav = this.el.querySelector("nav");
    if (nav && this.saveScroll) {
      nav.removeEventListener("scroll", this.saveScroll);
    }
  },
};

Hooks.DblClickDrillDown = {
  mounted() {
    let timer;
    this.el.addEventListener("click", (e) => {
      clearTimeout(timer);
      timer = setTimeout(() => {}, 250);
    });

    this.el.addEventListener("dblclick", (e) => {
      e.preventDefault();
      clearTimeout(timer);
      this.pushEvent("drill_down", { id: this.el.dataset.drillId });
    });
  },
};

// The "enable browser notifications" banner inside the messenger. Requests
// permission only on a real click (never on page load — browsers
// penalize/ignore silent auto-prompts, and asking outside of an explicit
// user action is exactly the annoying pattern we want to avoid). Hides
// itself once answered, or once dismissed via "not now" (remembered per
// browser so it doesn't nag on every visit).
Hooks.NotificationBanner = {
  mounted() {
    this.sync();
    this.el.querySelector("[data-allow]")?.addEventListener("click", () => {
      if (!("Notification" in window)) return;
      Notification.requestPermission().then(() => this.sync());
    });
    this.el.querySelector("[data-dismiss]")?.addEventListener("click", () => {
      localStorage.setItem("chat-notif-banner-dismissed", "1");
      this.sync();
    });
  },
  sync() {
    const supported = "Notification" in window;
    const answered = supported && Notification.permission !== "default";
    const dismissed = localStorage.getItem("chat-notif-banner-dismissed") === "1";
    this.el.hidden = !supported || answered || dismissed;
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

// Click-to-preview lightbox for read-only content images (block-based
// `:image` blocks and read-only TipTap-rendered images alike, both marked
// with `.js-lightbox-img`). A single document-level delegated listener
// rather than a per-hook one, since TipTap's own images live inside a
// `phx-update="ignore"` container LiveView never re-scans, and delegation
// means new images (patched in later) work without re-attaching anything.
document.addEventListener("click", (e) => {
  const img = e.target.closest(".js-lightbox-img");
  if (!img) return;

  const lightbox = document.getElementById("lightbox");
  const lightboxImg = document.getElementById("lightbox-img");
  if (!lightbox || !lightboxImg) return;

  lightboxImg.src = img.currentSrc || img.src;
  lightboxImg.alt = img.alt || "";
  lightbox.showModal();
});

// Scrolls the open thread either to the bottom (new message just sent/
// received) or to the "new messages" divider (just opened a conversation
// with unread history) — see AthenaWeb.MessengerLive.Index.
window.addEventListener("phx:scroll_thread", (e) => {
  const to = e.detail.to;

  setTimeout(() => {
    const container = document.querySelector('[id^="messages-"][phx-update="stream"]');
    if (!container) return;

    if (to && to !== "bottom") {
      const target = document.getElementById(to);
      if (target) {
        target.scrollIntoView({ block: "center" });
        return;
      }
    }

    container.scrollTop = container.scrollHeight;
  }, 50);
});

// In-app toast + (when the tab is hidden/unfocused and permission was
// granted) a native browser Notification for a new chat message — pushed
// from AthenaWeb.Hooks.Messenger on every authenticated page, not just
// the messenger itself, so a message still gets noticed while you're
// elsewhere in the LMS.
window.addEventListener("phx:new_message_notification", (e) => {
  const { title, preview, url, conversation_id } = e.detail;

  showChatToast(title, preview, url);

  const tabHidden = document.hidden || !document.hasFocus();
  if (tabHidden && "Notification" in window && Notification.permission === "granted") {
    const notification = new Notification(title, {
      body: preview,
      tag: `athena-message-${conversation_id}`,
    });
    notification.onclick = () => {
      window.focus();
      window.location.href = url;
      notification.close();
    };
  }
});

function chatToastContainer() {
  let container = document.getElementById("chat-toast-container");
  if (!container) {
    container = document.createElement("div");
    container.id = "chat-toast-container";
    container.style.cssText =
      "position:fixed;bottom:1rem;right:1rem;z-index:9999;display:flex;flex-direction:column;gap:0.5rem;max-width:22rem;";
    document.body.appendChild(container);
  }
  return container;
}

function showChatToast(title, preview, url) {
  const toast = document.createElement("a");
  toast.href = url;
  toast.className =
    "block bg-base-100 border border-base-300 rounded-box shadow-lg p-3 hover:bg-base-200 transition-colors cursor-pointer";
  toast.innerHTML =
    '<div class="font-bold text-sm truncate"></div><div class="text-sm text-base-content/70 truncate"></div>';
  toast.querySelector("div:first-child").textContent = title;
  toast.querySelector("div:last-child").textContent = preview;

  const container = chatToastContainer();
  container.appendChild(toast);

  setTimeout(() => {
    toast.remove();
  }, 6000);
}

window.addEventListener("phx:scroll_to_block", (e) => {
  const blockId = e.detail.id;
  if (!blockId) return;

  setTimeout(() => {
    const element =
      document.querySelector(`[data-id="${blockId}"]`) ||
      document.querySelector(`#block-wrapper-${blockId}`);

    if (!element) {
      console.warn(`[Athena] Block ${blockId} not found for scroll`);
      return;
    }

    element.scrollIntoView({
      behavior: "smooth",
      block: "start",
    });
  }, 150);
});

const liveSocket = new LiveSocket("/live", Socket, {
  uploaders: Uploaders,
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { ...colocatedHooks, ...Hooks },
});

const savedTheme = localStorage.getItem("phx:theme") || "system";
const htmlDoc = document.documentElement;

const applyTheme = (theme) => {
  let activeTheme = theme;
  if (theme === "system") {
    activeTheme = window.matchMedia("(prefers-color-scheme: dark)").matches
      ? "dark"
      : "light";
  }
  htmlDoc.setAttribute("data-theme", activeTheme);

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
