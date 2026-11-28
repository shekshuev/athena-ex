import powershell from "highlight.js/lib/languages/powershell";
import zig from "highlightjs-zig";
import { common, createLowlight } from "lowlight";

export const lowlight = createLowlight(common);
// The Tiptap picker includes executable modes plus highlight-only languages.
// These two grammars are absent from lowlight's common bundle.
lowlight.register("powershell", powershell);
lowlight.register("zig", zig);
