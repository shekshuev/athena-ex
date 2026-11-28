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
import { StreamLanguage } from "@codemirror/language";
import { csharp, kotlin } from "@codemirror/legacy-modes/mode/clike";
import { swift } from "@codemirror/legacy-modes/mode/swift";
import { zig } from "codemirror-lang-zig";

const languages = {
  python,
  cpp,
  c: cpp,
  sql,
  javascript,
  typescript: () => javascript({ typescript: true }),
  csharp: () => StreamLanguage.define(csharp),
  kotlin: () => StreamLanguage.define(kotlin),
  swift: () => StreamLanguage.define(swift),
  zig,
  html,
  css,
  json,
  markdown,
  yaml,
  rust,
  go,
  java,
  php,
  xml,
};

// Receives CodeMirror modes from Execution.cm_lang/1, not runner identifiers.
export function codeEditorLanguage(mode) {
  return (Object.hasOwn(languages, mode) ? languages[mode] : python)();
}

// LiveView patches data attributes even when the editor's children are ignored.
export function updateCodeEditorLanguage(hook) {
  const mode = hook.el.dataset.language;
  if (mode === hook.languageMode) return;

  hook.editor.dispatch({
    effects: hook.languageCompartment.reconfigure(codeEditorLanguage(mode)),
  });
  hook.languageMode = mode;
}
