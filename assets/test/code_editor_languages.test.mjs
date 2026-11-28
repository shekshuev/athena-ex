import assert from "node:assert/strict";
import test from "node:test";
import { Compartment, EditorState } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";
import { highlightTree, classHighlighter } from "@lezer/highlight";
import { lowlight } from "../js/code_block_highlighting.js";
import { codeEditorLanguage, updateCodeEditorLanguage } from "../js/code_editor_languages.js";

const samples = {
  c: 'int main(void) { return 0; } // comment',
  csharp: 'class Program { static string name = "hello"; } // comment',
  java: 'class Main { String name = "hello"; } // comment',
  javascript: 'const name = "hello"; // comment',
  typescript: 'const name: string = "hello"; // comment',
  go: 'package main\nvar name = "hello" // comment',
  kotlin: 'val name: String = "hello" // comment',
  swift: 'let name: String = "hello" // comment',
  rust: 'fn main() { let name = "hello"; } // comment',
  zig: 'const name: []const u8 = "hello"; // comment',
};

for (const [mode, doc] of Object.entries(samples)) {
  test(`${mode} parses and highlights executable source`, () => {
    const state = EditorState.create({ doc, extensions: [codeEditorLanguage(mode)] });
    const tree = syntaxTree(state);
    assert.equal(tree.length, doc.length);
    const tokens = [];
    highlightTree(tree, classHighlighter, (from, to, classes) => {
      tokens.push({ text: doc.slice(from, to), classes });
    });
    assert.ok(tokens.some(({ classes }) => classes.includes("tok-keyword")), "keywords highlighted");
    assert.ok(tokens.some(({ text, classes }) => text.includes("comment") && classes.includes("tok-comment")), "comments highlighted");
    if (mode !== "c") {
      assert.ok(tokens.some(({ text, classes }) => text.includes("hello") && classes.includes("tok-string")), "strings highlighted");
    }
    if (!["csharp", "kotlin", "swift"].includes(mode)) {
      tree.iterate({ enter(node) { assert.equal(node.type.isError, false, `parse error at ${node.from}`); } });
    }
  });
}

test("existing editor modes and the Python fallback remain available", () => {
  for (const mode of ["python", "cpp", "sql", "html", "css", "json", "markdown", "yaml", "php", "xml", "unknown", undefined, "__proto__"]) {
    const state = EditorState.create({ doc: "", extensions: [codeEditorLanguage(mode)] });
    assert.ok(syntaxTree(state).type.name);
  }
});

test("Tiptap can highlight every new executable language", () => {
  for (const [mode, doc] of Object.entries(samples)) {
    assert.ok(lowlight.registered(mode), `${mode} registered`);
    const highlighted = lowlight.highlight(mode, doc);
    assert.ok(highlighted.children.some((node) => node.type === "element"), `${mode} has highlighted tokens`);
  }
  assert.ok(lowlight.registered("powershell"));
});

test("updating the same editor switches grammar without changing code, selection, or history", async () => {
  const { history, undo, undoDepth } = await import("@codemirror/commands");
  const { javascriptLanguage, typescriptLanguage } = await import("@codemirror/lang-javascript");
  const languageCompartment = new Compartment();
  let state = EditorState.create({
    doc: "const value: string = 'hello';",
    selection: { anchor: 6 },
    extensions: [languageCompartment.of(codeEditorLanguage("javascript")), history()],
  });
  state = state.update({ changes: { from: state.doc.length, insert: " // note" } }).state;
  let dispatchCount = 0;
  const editor = {
    dispatch(transaction) {
      dispatchCount++;
      const update = state.update(transaction);
      assert.equal(update.docChanged, false);
      state = update.state;
    },
  };
  const hook = {
    el: { dataset: { language: "typescript" } },
    languageMode: "javascript", languageCompartment, editor,
  };
  const doc = state.doc.toString();
  const selection = state.selection.toJSON();
  assert.ok(javascriptLanguage.isActiveAt(state, 0));
  updateCodeEditorLanguage(hook);
  assert.ok(typescriptLanguage.isActiveAt(state, 0));
  assert.equal(hook.languageMode, "typescript");
  assert.equal(state.doc.toString(), doc);
  assert.deepEqual(state.selection.toJSON(), selection);
  assert.equal(undoDepth(state), 1);
  updateCodeEditorLanguage(hook);
  assert.equal(dispatchCount, 1, "unrelated patches do not reconfigure");
  for (const mode of ["csharp", "kotlin", "swift", "zig", "python"]) {
    hook.el.dataset.language = mode;
    updateCodeEditorLanguage(hook);
    assert.equal(state.doc.toString(), doc);
    assert.deepEqual(state.selection.toJSON(), selection);
    assert.equal(undoDepth(state), 1);
  }
  assert.equal(undo({ state, dispatch: (transaction) => { state = transaction.state; } }), true);
  assert.equal(state.doc.toString(), "const value: string = 'hello';");
});
