import { Node, mergeAttributes } from "@tiptap/core";

// Deterministic fallback color for a character with no avatar, so the same
// name always gets the same color across the doc (and across reloads).
const PALETTE = [
  "#ef4444",
  "#f97316",
  "#f59e0b",
  "#84cc16",
  "#10b981",
  "#06b6d4",
  "#3b82f6",
  "#8b5cf6",
  "#ec4899",
];

export const colorForName = (name) => {
  const str = (name || "").trim() || "?";
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    hash = (hash << 5) - hash + str.charCodeAt(i);
    hash |= 0;
  }
  return PALETTE[Math.abs(hash) % PALETTE.length];
};

const firstLetter = (name) => (name || "").trim().charAt(0).toUpperCase() || "?";

// A plain centered modal (backdrop + dialog), matching the rest of the app's
// modals, rather than a floating tippy dropdown anchored to the trigger
// element (which mispositions inside a ProseMirror contentEditable tree).
const openCharacterPicker = (getCharacters, onSelect, onManageCharacters) => {
  const backdrop = document.createElement("div");
  backdrop.className = "tiptap-dialogue-modal-backdrop";

  const dialog = document.createElement("div");
  dialog.className = "tiptap-dialogue-modal";

  const close = () => backdrop.remove();

  const header = document.createElement("div");
  header.className = "tiptap-dialogue-modal-header";

  const title = document.createElement("span");
  title.textContent = "Choose speaker";
  header.appendChild(title);

  const closeButton = document.createElement("button");
  closeButton.type = "button";
  closeButton.className = "tiptap-dialogue-modal-close";
  closeButton.textContent = "✕";
  closeButton.addEventListener("click", close);
  header.appendChild(closeButton);

  dialog.appendChild(header);

  const list = document.createElement("div");
  list.className = "tiptap-dialogue-picker";

  const characters = getCharacters();

  if (characters.length === 0) {
    const empty = document.createElement("div");
    empty.className = "tiptap-dialogue-picker-empty";
    empty.textContent = "No characters yet.";
    list.appendChild(empty);
  }

  for (const character of characters) {
    const item = document.createElement("button");
    item.type = "button";
    item.className = "tiptap-dialogue-picker-item";

    const avatar = document.createElement("span");
    avatar.className = "tiptap-dialogue-picker-avatar";
    if (character.avatarUrl) {
      avatar.style.backgroundImage = `url(${character.avatarUrl})`;
    } else {
      avatar.style.backgroundColor = character.color || colorForName(character.name);
      avatar.textContent = firstLetter(character.name);
    }

    const label = document.createElement("span");
    label.textContent = character.name;

    item.appendChild(avatar);
    item.appendChild(label);
    item.addEventListener("click", () => {
      onSelect(character);
      close();
    });
    list.appendChild(item);
  }

  dialog.appendChild(list);

  if (onManageCharacters) {
    const createItem = document.createElement("button");
    createItem.type = "button";
    createItem.className = "tiptap-dialogue-modal-create";
    createItem.textContent = "+ Create character";
    createItem.addEventListener("click", () => {
      onManageCharacters();
      close();
    });
    dialog.appendChild(createItem);
  }

  backdrop.appendChild(dialog);
  backdrop.addEventListener("mousedown", (e) => {
    if (e.target === backdrop) close();
  });

  const onKeydown = (e) => {
    if (e.key === "Escape") {
      close();
      document.removeEventListener("keydown", onKeydown);
    }
  };
  document.addEventListener("keydown", onKeydown);

  document.body.appendChild(backdrop);
};

export const Dialogue = Node.create({
  name: "dialogue",
  group: "block",
  content: "dialogueLine+",
  defining: true,
  isolating: true,

  parseHTML() {
    return [{ tag: 'div[data-type="dialogue"]' }];
  },

  renderHTML({ HTMLAttributes }) {
    return [
      "div",
      mergeAttributes(HTMLAttributes, { "data-type": "dialogue", class: "tiptap-dialogue" }),
      0,
    ];
  },

  addNodeView() {
    return ({ editor, getPos }) => {
      const dom = document.createElement("div");
      dom.className = "tiptap-dialogue";

      const lines = document.createElement("div");
      lines.className = "tiptap-dialogue-content";
      dom.appendChild(lines);

      if (editor.isEditable) {
        const addButton = document.createElement("button");
        addButton.type = "button";
        addButton.className = "tiptap-dialogue-add-line";
        addButton.contentEditable = "false";
        addButton.textContent = "+ Add line";

        addButton.addEventListener("mousedown", (e) => {
          e.preventDefault();
          e.stopPropagation();

          if (typeof getPos !== "function") return;
          const pos = getPos();
          const dialogueNode = editor.state.doc.nodeAt(pos);
          if (!dialogueNode) return;

          const lastLine = dialogueNode.lastChild;
          const attrs = lastLine
            ? { ...lastLine.attrs }
            : { characterId: null, name: "", avatarUrl: null, color: null, side: "left" };

          const endPos = pos + dialogueNode.nodeSize - 1;

          editor
            .chain()
            .focus()
            .insertContentAt(endPos, { type: "dialogueLine", attrs, content: [] })
            .setTextSelection(endPos + 1)
            .run();
        });

        dom.appendChild(addButton);
      }

      return {
        dom,
        contentDOM: lines,
        update(updatedNode) {
          return updatedNode.type.name === "dialogue";
        },
      };
    };
  },
});

export const DialogueLine = Node.create({
  name: "dialogueLine",
  content: "inline*",
  defining: true,

  addOptions() {
    return {
      getCharacters: () => [],
      onManageCharacters: null,
    };
  },

  addAttributes() {
    return {
      characterId: { default: null },
      name: { default: "" },
      avatarUrl: { default: null },
      color: { default: null },
      side: { default: "left" },
    };
  },

  parseHTML() {
    return [
      {
        tag: 'div[data-type="dialogue-line"]',
        contentElement: ".dialogue-text",
        getAttrs: (el) => ({
          characterId: el.getAttribute("data-character-id") || null,
          name: el.getAttribute("data-name") || "",
          avatarUrl: el.getAttribute("data-avatar-url") || null,
          color: el.getAttribute("data-color") || null,
          side: el.getAttribute("data-side") || "left",
        }),
      },
    ];
  },

  renderHTML({ node, HTMLAttributes }) {
    return [
      "div",
      mergeAttributes(HTMLAttributes, {
        "data-type": "dialogue-line",
        "data-character-id": node.attrs.characterId,
        "data-name": node.attrs.name,
        "data-avatar-url": node.attrs.avatarUrl,
        "data-color": node.attrs.color,
        "data-side": node.attrs.side || "left",
        class: "tiptap-dialogue-line",
      }),
      ["div", { class: "dialogue-text" }, 0],
    ];
  },

  addNodeView() {
    return ({ node, editor, getPos }) => {
      let currentNode = node;

      const dom = document.createElement("div");
      dom.className = "tiptap-dialogue-line";

      const avatar = document.createElement("div");
      avatar.className = "tiptap-dialogue-avatar";
      avatar.contentEditable = "false";

      const col = document.createElement("div");
      col.className = "tiptap-dialogue-col";

      const nameButton = document.createElement("button");
      nameButton.type = "button";
      nameButton.className = "tiptap-dialogue-name";
      nameButton.contentEditable = "false";

      const bubble = document.createElement("div");
      bubble.className = "tiptap-dialogue-bubble";

      const content = document.createElement("div");
      content.className = "dialogue-text";
      bubble.appendChild(content);

      col.appendChild(nameButton);
      col.appendChild(bubble);

      dom.appendChild(avatar);
      dom.appendChild(col);

      const patchAttrs = (patch) => {
        const pos = typeof getPos === "function" ? getPos() : null;
        if (typeof pos !== "number") return;

        editor.commands.command(({ tr }) => {
          tr.setNodeMarkup(pos, undefined, { ...currentNode.attrs, ...patch });
          return true;
        });
      };

      let controls = null;
      let leftButton = null;
      let rightButton = null;

      if (editor.isEditable) {
        controls = document.createElement("div");
        controls.className = "tiptap-dialogue-line-controls";
        controls.contentEditable = "false";

        leftButton = document.createElement("button");
        leftButton.type = "button";
        leftButton.className = "tiptap-dialogue-line-btn";
        leftButton.title = "Move bubble left";
        leftButton.textContent = "←";
        leftButton.addEventListener("mousedown", (e) => {
          e.preventDefault();
          e.stopPropagation();
          patchAttrs({ side: "left" });
        });

        rightButton = document.createElement("button");
        rightButton.type = "button";
        rightButton.className = "tiptap-dialogue-line-btn";
        rightButton.title = "Move bubble right";
        rightButton.textContent = "→";
        rightButton.addEventListener("mousedown", (e) => {
          e.preventDefault();
          e.stopPropagation();
          patchAttrs({ side: "right" });
        });

        const deleteButton = document.createElement("button");
        deleteButton.type = "button";
        deleteButton.className = "tiptap-dialogue-line-btn is-danger";
        deleteButton.title = "Delete line";
        deleteButton.textContent = "✕";
        deleteButton.addEventListener("mousedown", (e) => {
          e.preventDefault();
          e.stopPropagation();

          const pos = typeof getPos === "function" ? getPos() : null;
          if (typeof pos !== "number") return;

          editor.commands.command(({ tr, state }) => {
            const $pos = state.doc.resolve(pos);
            const dialogueNode = $pos.parent;
            if (dialogueNode.type.name !== "dialogue") return false;

            if (dialogueNode.childCount <= 1) {
              const dialoguePos = $pos.before($pos.depth);
              tr.delete(dialoguePos, dialoguePos + dialogueNode.nodeSize);
            } else {
              tr.delete(pos, pos + currentNode.nodeSize);
            }
            return true;
          });
        });

        controls.appendChild(leftButton);
        controls.appendChild(rightButton);
        controls.appendChild(deleteButton);
        dom.appendChild(controls);
      }

      const render = (n) => {
        const { name, avatarUrl, color, side } = n.attrs;
        nameButton.textContent = name || "Choose speaker…";
        dom.dataset.side = side || "left";

        if (avatarUrl) {
          avatar.style.backgroundImage = `url(${avatarUrl})`;
          avatar.style.backgroundColor = "";
          avatar.textContent = "";
        } else {
          avatar.style.backgroundImage = "";
          avatar.style.backgroundColor = color || colorForName(name);
          avatar.textContent = firstLetter(name);
        }

        if (leftButton && rightButton) {
          leftButton.classList.toggle("is-active", (side || "left") === "left");
          rightButton.classList.toggle("is-active", side === "right");
        }
      };

      render(node);

      if (editor.isEditable) {
        const pickSpeaker = (e) => {
          e.preventDefault();
          e.stopPropagation();
          openCharacterPicker(
            this.options.getCharacters,
            (character) => {
              patchAttrs({
                characterId: character.id,
                name: character.name,
                avatarUrl: character.avatarUrl,
                color: character.color,
              });

              const pos = typeof getPos === "function" ? getPos() : null;
              if (typeof pos === "number") {
                editor.chain().focus(pos + 1).run();
              }
            },
            this.options.onManageCharacters,
          );
        };

        nameButton.addEventListener("mousedown", pickSpeaker);
        avatar.addEventListener("mousedown", pickSpeaker);
      } else {
        nameButton.disabled = true;
      }

      return {
        dom,
        contentDOM: content,
        update(updatedNode) {
          if (updatedNode.type.name !== "dialogueLine") return false;
          currentNode = updatedNode;
          render(updatedNode);
          return true;
        },
      };
    };
  },

  addKeyboardShortcuts() {
    return {
      Enter: () => {
        const { editor } = this;
        const { state } = editor;
        const { $from, empty } = state.selection;

        if ($from.parent.type.name !== "dialogueLine") return false;

        let dialogueDepth = null;
        for (let d = $from.depth; d > 0; d--) {
          if ($from.node(d).type.name === "dialogue") {
            dialogueDepth = d;
            break;
          }
        }
        if (dialogueDepth == null) return false;

        const isEmptyLine = empty && $from.parent.content.size === 0;

        if (isEmptyLine) {
          const afterDialoguePos = $from.after(dialogueDepth);
          return editor
            .chain()
            .insertContentAt(afterDialoguePos, { type: "paragraph" })
            .setTextSelection(afterDialoguePos + 1)
            .run();
        }

        const attrs = $from.parent.attrs;
        const afterLinePos = $from.after($from.depth);

        return editor
          .chain()
          .insertContentAt(afterLinePos, { type: "dialogueLine", attrs, content: [] })
          .setTextSelection(afterLinePos + 1)
          .run();
      },
    };
  },
});

export const insertDialogue = (editor) =>
  editor
    .chain()
    .focus()
    .insertContent({
      type: "dialogue",
      content: [
        {
          type: "dialogueLine",
          attrs: { characterId: null, name: "", avatarUrl: null, color: null, side: "left" },
        },
      ],
    })
    .run();
