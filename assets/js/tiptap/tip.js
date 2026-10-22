import { Node, mergeAttributes } from "@tiptap/core";

// A boxed aside - "tip" - for calling out a note, a caveat or a warning
// inside lesson text. Four variants, mapped to the theme's semantic colour
// tokens (see `.tiptap-tip` in app.css), so a tip is legible on both themes
// without the author picking a colour by hand.
export const TIP_VARIANTS = ["info", "success", "warning", "error"];

const DEFAULT_VARIANT = "info";

// Written out as literal class strings so Tailwind's heroicons plugin finds
// them when it scans this file (`@source "../js"` in app.css).
const ICONS = {
  info: "hero-information-circle",
  success: "hero-check-circle",
  warning: "hero-exclamation-triangle",
  error: "hero-x-circle",
};

const normalizeVariant = (variant) =>
  TIP_VARIANTS.includes(variant) ? variant : DEFAULT_VARIANT;

export const Tip = Node.create({
  name: "tip",
  group: "block",
  content: "block+",
  defining: true,

  addAttributes() {
    return {
      variant: {
        default: DEFAULT_VARIANT,
        parseHTML: (element) => normalizeVariant(element.getAttribute("data-variant")),
        renderHTML: (attributes) => ({ "data-variant": normalizeVariant(attributes.variant) }),
      },
    };
  },

  parseHTML() {
    return [{ tag: 'div[data-type="tip"]', contentElement: ".tip-body" }];
  },

  renderHTML({ HTMLAttributes }) {
    return [
      "div",
      mergeAttributes(HTMLAttributes, { "data-type": "tip", class: "tiptap-tip" }),
      ["div", { class: "tip-body" }, 0],
    ];
  },

  // The icon has to be built here rather than via `renderHTML`'s
  // `HTMLAttributes`: a NodeView-backed node never calls `renderHTML`, so
  // anything set there would silently never reach the DOM (same trap as
  // `ResizableImage` in app.js).
  addNodeView() {
    return ({ node }) => {
      const dom = document.createElement("div");
      dom.className = "tiptap-tip";
      dom.setAttribute("data-type", "tip");

      const icon = document.createElement("span");
      icon.className = "tip-icon";
      icon.contentEditable = "false";

      const body = document.createElement("div");
      body.className = "tip-body";

      const applyVariant = (variant) => {
        const normalized = normalizeVariant(variant);
        dom.setAttribute("data-variant", normalized);
        icon.innerHTML = `<span class="${ICONS[normalized]} size-5"></span>`;
      };

      applyVariant(node.attrs.variant);
      dom.append(icon, body);

      return {
        dom,
        contentDOM: body,
        update: (updatedNode) => {
          if (updatedNode.type.name !== "tip") return false;
          applyVariant(updatedNode.attrs.variant);
          return true;
        },
        // The icon is decoration, not content: keep ProseMirror from trying
        // to read the `innerHTML` swap above back as a document change.
        ignoreMutation: (mutation) => icon.contains(mutation.target),
      };
    };
  },

  addCommands() {
    return {
      setTip:
        (variant = DEFAULT_VARIANT) =>
        ({ commands }) =>
          commands.wrapIn(this.name, { variant: normalizeVariant(variant) }),

      unsetTip:
        () =>
        ({ commands }) =>
          commands.lift(this.name),

      toggleTip:
        (variant = DEFAULT_VARIANT) =>
        ({ editor, commands }) =>
          editor.isActive(this.name)
            ? commands.lift(this.name)
            : commands.wrapIn(this.name, { variant: normalizeVariant(variant) }),
    };
  },

  addKeyboardShortcuts() {
    return {
      "Mod-Shift-i": () => this.editor.commands.toggleTip(),
    };
  },
});
